//
//  FolderListStack.swift
//  Docky
//
//  The folder List view, built to behave like the macOS Dock's List stack:
//  hover highlights, subfolders cascade to the side, the keyboard works
//  (↑ ↓ → ← ⏎ ⎋, type-to-select), and Space toggles Quick Look while the
//  stack stays open.
//
//  Why not NSMenu (what List used to be): while a menu tracks, key events
//  never reach the app, main-queue work doesn't run and QLPreviewPanel
//  can't load. Instead, one borderless `.nonactivatingPanel` that can
//  become key (the StartMenuPanel / Spotlight pattern) takes the keyboard
//  without bringing Docky to the front, and holds every open column:
//
//   tile click ─▶ FolderListStackPresenter ─▶ FolderListStackController
//                                               │ columns[0…n] (async loads,
//                                               │ folder watchers)
//                                               ▼
//   FolderListPanel (key, child of MainWindow) ─ sendEvent ─▶ handleKey
//     └ FolderListStackView ─ hover / click / drag / drop ─▶ controller
//   Quick Look: FolderQuickLookController.show(owner:), in front of the
//   panel, retargeted as the highlight moves.
//

import AppKit
import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct FolderListStackPresenter: NSViewRepresentable {
    let tile: FolderTile
    let initialSnapshot: FolderContentsSnapshot
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge

    func makeCoordinator() -> FolderListStackController {
        FolderListStackController()
    }

    func makeNSView(context: Context) -> FolderListAnchorView {
        FolderListAnchorView()
    }

    func updateNSView(_ nsView: FolderListAnchorView, context: Context) {
        let controller = context.coordinator
        let binding = $isPresented
        controller.onDismiss = {
            guard binding.wrappedValue else { return }
            binding.wrappedValue = false
        }
        if isPresented {
            controller.present(
                tile: tile,
                initialSnapshot: initialSnapshot,
                anchorView: nsView,
                edge: preferredEdge
            )
        } else {
            controller.dismiss()
        }
    }

    static func dismantleNSView(_ nsView: FolderListAnchorView, coordinator: FolderListStackController) {
        coordinator.dismiss()
    }
}

final class FolderListAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Borderless, non-activating, but able to become key: keystrokes reach us
/// while the frontmost app keeps its menu bar. Keys are handled in
/// `sendEvent` so the hosted SwiftUI views (ScrollView) can't swallow
/// arrows or Space first.
final class FolderListPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // columns draw their own; the window is mostly transparent
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            FolderListStackController.log.debug("key \(event.keyCode) repeat=\(event.isARepeat)")
            if keyHandler?(event) == true { return }
        }
        super.sendEvent(event)
    }
}

final class FolderListStackController: NSObject, ObservableObject {
    static let log = Logger(subsystem: "gt.quintero.Docky", category: "FolderList")

    enum Row: Hashable {
        case item(URL)
        case openInFinder
    }

    enum LoadState: Equatable {
        case loading, loaded, unreadable
    }

    struct Column: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let isRoot: Bool
        var rows: [Row] = []
        var titles: [Row: String] = [:]
        var folders: Set<URL> = []
        var state: LoadState = .loading
        var highlighted: Int?
        var width: CGFloat = FolderListLayout.minWidth
        /// Where the column sits inside the panel, top-left origin (SwiftUI).
        var frameInPanel: CGRect = .zero
        var screenFrame: CGRect = .zero

        var itemCount: Int {
            rows.filter { if case .item = $0 { return true } else { return false } }.count
        }
    }

    @Published private(set) var columns: [Column] = []
    /// Bumped to ask a column's ScrollViewReader to reveal a row.
    @Published private(set) var scrollTarget: (column: UUID, row: Row, token: Int)?

    var onDismiss: (() -> Void)?

    private var tile: FolderTile?
    private weak var anchorView: NSView?
    private weak var mainWindow: MainWindow?
    private var side: FolderListLayout.Side = .above
    private var panel: FolderListPanel?
    private(set) var isPresented = false
    private var presentedAt: TimeInterval = 0
    private var focusedColumn = 0
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var hoverOpenTask: Task<Void, Never>?
    private var deferredHoverTask: Task<Void, Never>?
    private var springLoadTask: Task<Void, Never>?
    private var highlightFirstOnLoad: Set<UUID> = []
    /// Row frames in each column's viewport (top-left origin), reported by
    /// the rows. Not published: only read when placing a child column.
    private var rowFrames: [UUID: [Row: CGRect]] = [:]
    private var pointerOrigin: CGPoint?
    private var typeBuffer = ""
    private var typeBufferAt: TimeInterval = 0
    private var scrollToken = 0
    private let hoverOpenDelay: TimeInterval = 0.2
    private let safeTriangleGrace: TimeInterval = 0.3
    private let springLoadDwell: TimeInterval = 0.7
    private let shadowInset: CGFloat = 24

    private var watcherOwnerID: String {
        "folder-list:\(ObjectIdentifier(self).hashValue)"
    }

    // MARK: - Presentation

    func present(tile: FolderTile, initialSnapshot: FolderContentsSnapshot, anchorView: NSView, edge: NSRectEdge) {
        self.tile = tile
        self.anchorView = anchorView
        guard !isPresented, let main = anchorView.window as? MainWindow else { return }
        isPresented = true
        presentedAt = ProcessInfo.processInfo.systemUptime
        mainWindow = main
        side = Self.side(for: edge)
        focusedColumn = 0

        var root = Column(url: tile.url, isRoot: true)
        apply(snapshot: initialSnapshot, to: &root)
        columns = [root]
        beginWatching(root.url)
        reload(columnID: root.id)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        main.addChildWindow(panel, ordered: .above)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        main.beginInteraction()
        layout()
        panel.makeKeyAndOrderFront(nil)

        installMonitors()
        observeChanges(main: main)
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        hoverOpenTask?.cancel()
        deferredHoverTask?.cancel()
        springLoadTask?.cancel()
        loadTasks.values.forEach { $0.cancel() }
        loadTasks.removeAll()
        FolderQuickLookController.shared.close(owner: self)
        removeMonitors()
        cancellables.removeAll()
        columns.forEach { endWatching($0.url) }
        if let panel {
            mainWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        mainWindow?.endInteraction()
        columns = []
        rowFrames.removeAll()
        highlightFirstOnLoad.removeAll()
        typeBuffer = ""
        let onDismiss = self.onDismiss
        DispatchQueue.main.async { onDismiss?() }
    }

    private func makePanel() -> FolderListPanel {
        let panel = FolderListPanel()
        let hosting = NSHostingView(rootView: FolderListStackView(controller: self))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        return panel
    }

    private static func side(for edge: NSRectEdge) -> FolderListLayout.Side {
        switch edge {
        case .minY: .below
        case .maxX: .right
        case .minX: .left
        default: .above
        }
    }

    private func observeChanges(main: MainWindow) {
        let center = NotificationCenter.default
        center.publisher(for: NSWindow.didMoveNotification, object: main)
            .merge(with: center.publisher(for: NSWindow.didResizeNotification, object: main))
            .merge(with: center.publisher(for: NSWindow.didChangeScreenNotification, object: main))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)

        FolderAccessService.shared.$changeToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadAll() }
            .store(in: &cancellables)

        // If Quick Look took key (the user clicked it), hand the keyboard
        // back to the list as soon as the pointer is over it again.
        if let panel {
            center.publisher(for: NSWindow.didResignKeyNotification, object: panel)
                .sink { _ in FolderListStackController.log.debug("panel resigned key") }
                .store(in: &cancellables)
        }
    }

    // MARK: - Layout

    private func layout() {
        guard isPresented, let panel, let anchorView, let window = anchorView.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let anchor = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        let visible = screen.visibleFrame

        let sizes = columns.map { column in
            CGSize(
                width: column.width,
                height: FolderListLayout.columnHeight(
                    rowCount: column.state == .loaded ? column.itemCount : 1,
                    hasDivider: column.isRoot,
                    visibleHeight: visible.height
                ) + (column.isRoot ? FolderListLayout.rowHeight : 0)
            )
        }

        // Each child aligns to its opener row, whose screen position depends
        // on the parent's frame, so place columns one at a time.
        var frames: [CGRect] = []
        var openerTops: [CGFloat] = []
        for index in sizes.indices {
            if index > 0 {
                let parent = columns[index - 1]
                let parentFrame = frames[index - 1]
                let rowIndex = parent.highlighted ?? 0
                let rowRect = parent.rows.indices.contains(rowIndex)
                    ? rowFrames[parent.id]?[parent.rows[rowIndex]]
                    : nil
                let rowMinY = rowRect?.minY
                    ?? (FolderListLayout.verticalPadding + CGFloat(rowIndex) * FolderListLayout.rowHeight)
                openerTops.append(parentFrame.maxY - rowMinY)
            }
            frames = FolderListLayout.columnFrames(
                anchor: anchor,
                side: side,
                sizes: Array(sizes[0...index]),
                openerRowTops: openerTops,
                visible: visible
            )
        }

        guard let first = frames.first else { return }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
            .insetBy(dx: -shadowInset, dy: -shadowInset)
        for index in columns.indices where index < frames.count {
            let frame = frames[index]
            columns[index].screenFrame = frame
            columns[index].frameInPanel = CGRect(
                x: frame.minX - union.minX,
                y: union.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
        panel.setFrame(union.integral, display: true)
    }

    // MARK: - Loading

    private func apply(snapshot: FolderContentsSnapshot, to column: inout Column) {
        switch snapshot {
        case .unreadable:
            column.state = .unreadable
            column.rows = column.isRoot ? [.openInFinder] : []
        case .loaded:
            let urls = FolderAccessService.shared.sortedItems(in: snapshot, sortMode: tile?.sortMode ?? .dateAdded)
            column.rows = urls.map(Row.item) + (column.isRoot ? [.openInFinder] : [])
            column.titles = Dictionary(uniqueKeysWithValues: urls.map { (Row.item($0), FolderItemInfo.displayName(for: $0)) })
            column.titles[.openInFinder] = String(localized: "Open in Finder")
            column.folders = Set(urls.filter { FolderItemInfo.isNavigableFolder($0) })
            column.state = .loaded
        }
        let font = NSFont.menuFont(ofSize: 0)
        let longest = column.titles.values
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        column.width = FolderListLayout.columnWidth(longestTitleWidth: longest)

        // The highlighted item vanished (deleted, moved): drop the highlight;
        // the caller closes its submenu.
        if let highlighted = column.highlighted, highlighted >= column.rows.count {
            column.highlighted = nil
        }
    }

    private func reload(columnID: UUID) {
        guard let column = columns.first(where: { $0.id == columnID }) else { return }
        let url = column.url
        loadTasks[columnID]?.cancel()
        loadTasks[columnID] = Task { @MainActor [weak self] in
            let snapshot = await FolderAccessService.shared.refreshedSnapshot(of: url)
            guard !Task.isCancelled, let self,
                  let index = self.columns.firstIndex(where: { $0.id == columnID }) else { return }
            var updated = self.columns[index]
            let previouslyHighlighted = updated.highlighted.map { updated.rows[$0] }
            self.apply(snapshot: snapshot, to: &updated)
            if let previouslyHighlighted {
                updated.highlighted = updated.rows.firstIndex(of: previouslyHighlighted)
            }
            if self.highlightFirstOnLoad.remove(columnID) != nil, !updated.rows.isEmpty {
                updated.highlighted = 0
            }
            self.columns[index] = updated
            // A submenu whose opener row disappeared closes.
            if updated.highlighted == nil || (index + 1 < self.columns.count
                && updated.rows[updated.highlighted!] != .item(self.columns[index + 1].url)) {
                self.closeColumns(after: index)
            }
            self.layout()
            self.retargetQuickLook()
        }
    }

    private func reloadAll() {
        columns.map(\.id).forEach(reload(columnID:))
    }

    private func beginWatching(_ url: URL) {
        FolderAccessService.shared.beginWatching(url.standardizedFileURL, ownerID: watcherOwnerID)
    }

    private func endWatching(_ url: URL) {
        FolderAccessService.shared.endWatching(url.standardizedFileURL, ownerID: watcherOwnerID)
    }

    // MARK: - Columns

    private func openChild(of columnIndex: Int, row rowIndex: Int, focus: Bool) {
        guard columns.indices.contains(columnIndex),
              columns[columnIndex].rows.indices.contains(rowIndex),
              case .item(let url) = columns[columnIndex].rows[rowIndex],
              columns[columnIndex].folders.contains(url) else { return }

        if columnIndex + 1 < columns.count, columns[columnIndex + 1].url == url {
            if focus { focusColumn(columnIndex + 1, highlightFirst: true) }
            return
        }
        closeColumns(after: columnIndex)
        var child = Column(url: url, isRoot: false)
        apply(snapshot: FolderAccessService.shared.snapshot(of: url), to: &child)
        if focus { child.highlighted = child.rows.isEmpty ? nil : 0 }
        columns.append(child)
        beginWatching(url)
        if focus {
            focusedColumn = columns.count - 1
            if child.highlighted == nil { highlightFirstOnLoad.insert(child.id) }
        }
        reload(columnID: child.id)
        layout()
        retargetQuickLook()
    }

    private func focusColumn(_ index: Int, highlightFirst: Bool) {
        focusedColumn = index
        if highlightFirst, columns[index].highlighted == nil, !columns[index].rows.isEmpty {
            columns[index].highlighted = 0
        }
        retargetQuickLook()
    }

    private func closeColumns(after index: Int) {
        guard index + 1 < columns.count else { return }
        for column in columns[(index + 1)...] {
            endWatching(column.url)
            loadTasks[column.id]?.cancel()
            loadTasks[column.id] = nil
            rowFrames[column.id] = nil
        }
        columns.removeSubrange((index + 1)...)
        focusedColumn = min(focusedColumn, index)
        layout()
    }

    // MARK: - Highlight

    private func setHighlight(column columnIndex: Int, row rowIndex: Int?, openSubmenu: Bool) {
        guard columns.indices.contains(columnIndex) else { return }
        hoverOpenTask?.cancel()
        columns[columnIndex].highlighted = rowIndex
        focusedColumn = columnIndex

        let row = rowIndex.map { columns[columnIndex].rows[$0] }
        let childOpenForRow: Bool = {
            guard columnIndex + 1 < columns.count, case .item(let url) = row else { return false }
            return columns[columnIndex + 1].url == url
        }()
        if !childOpenForRow {
            closeColumns(after: columnIndex)
        }

        if openSubmenu, !childOpenForRow, let rowIndex, case .item(let url) = row,
           columns[columnIndex].folders.contains(url) {
            hoverOpenTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.hoverOpenDelay ?? 0) * 1_000_000_000))
                guard !Task.isCancelled, let self,
                      self.columns.indices.contains(columnIndex),
                      self.columns[columnIndex].highlighted == rowIndex else { return }
                self.openChild(of: columnIndex, row: rowIndex, focus: false)
            }
        }
        retargetQuickLook()
    }

    private func reveal(column columnIndex: Int, row rowIndex: Int) {
        scrollToken += 1
        scrollTarget = (columns[columnIndex].id, columns[columnIndex].rows[rowIndex], scrollToken)
    }

    private var highlightedURL: URL? {
        guard columns.indices.contains(focusedColumn),
              let index = columns[focusedColumn].highlighted,
              case .item(let url) = columns[focusedColumn].rows[index] else { return nil }
        return url
    }

    // MARK: - Mouse (called from the SwiftUI rows)

    func pointerMoved(column columnIndex: Int, row rowIndex: Int, location: CGPoint) {
        // Quick Look may have taken key if the user clicked it.
        if let panel, !panel.isKeyWindow { panel.makeKey() }
        deferredHoverTask?.cancel()

        // The safe-triangle origin is the last point inside the highlighted
        // row, so it doesn't creep while the pointer crosses other rows.
        let mouse = NSEvent.mouseLocation
        guard columns.indices.contains(columnIndex),
              columns[columnIndex].highlighted != rowIndex else {
            focusedColumn = columnIndex
            pointerOrigin = mouse
            return
        }

        // Heading for the open submenu? Don't switch it yet.
        if columnIndex + 1 < columns.count, let origin = pointerOrigin,
           FolderListLayout.isInSafeTriangle(point: mouse, origin: origin, child: columns[columnIndex + 1].screenFrame) {
            let grace = safeTriangleGrace
            deferredHoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                guard !Task.isCancelled, let self, self.isPresented else { return }
                self.setHighlight(column: columnIndex, row: rowIndex, openSubmenu: true)
            }
            return
        }
        setHighlight(column: columnIndex, row: rowIndex, openSubmenu: true)
        pointerOrigin = mouse
    }

    func click(column columnIndex: Int, row rowIndex: Int) {
        guard columns.indices.contains(columnIndex), columns[columnIndex].rows.indices.contains(rowIndex) else { return }
        switch columns[columnIndex].rows[rowIndex] {
        case .openInFinder:
            let url = columns[0].url
            Task { _ = await AppleScriptService.shared.openFinderWindow(for: url) }
            dismiss()
        case .item(let url):
            if columns[columnIndex].folders.contains(url) {
                setHighlight(column: columnIndex, row: rowIndex, openSubmenu: false)
                openChild(of: columnIndex, row: rowIndex, focus: false)
            } else {
                NSWorkspace.shared.open(url)
                dismiss()
            }
        }
    }

    func reportRowFrame(column id: UUID, row: Row, frame: CGRect) {
        rowFrames[id, default: [:]][row] = frame
    }

    // MARK: - Drag and drop

    func dragProvider(for url: URL) -> NSItemProvider {
        let provider = FolderItemInfo.dragItemProvider(for: url)
        // Same as the grid: get out of the way once a drag starts. The drag
        // session is owned at the screen level and survives the close.
        DispatchQueue.main.async { [weak self] in self?.dismiss() }
        return provider
    }

    func drop(_ providers: [NSItemProvider], into folder: URL) -> Bool {
        springLoadTask?.cancel()
        FolderItemInfo.moveDroppedFiles(providers: providers, into: folder) { [weak self] in
            DockDragService.shared.clear()
            self?.dismiss()
        }
        return true
    }

    /// Drag hovering a folder row: open it as a submenu after a dwell.
    func springLoad(column columnIndex: Int, row rowIndex: Int, isTargeted: Bool) {
        springLoadTask?.cancel()
        guard isTargeted else { return }
        let dwell = springLoadDwell
        springLoadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.setHighlight(column: columnIndex, row: rowIndex, openSubmenu: false)
            self.openChild(of: columnIndex, row: rowIndex, focus: false)
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        guard columns.indices.contains(focusedColumn) else { return false }

        switch Int(event.keyCode) {
        case 125: moveHighlight(by: 1)
        case 126: moveHighlight(by: -1)
        case 124: // →
            if let row = columns[focusedColumn].highlighted {
                openChild(of: focusedColumn, row: row, focus: true)
            }
        case 123: // ←
            if focusedColumn > 0 { stepBack() }
        case 36, 76: // ⏎
            activateHighlighted()
        case 53: // ⎋
            if focusedColumn > 0 { stepBack() } else { dismiss() }
        case 49: // Space
            if !event.isARepeat { toggleQuickLook() }
        default:
            return typeSelect(event)
        }
        return true
    }

    private func moveHighlight(by delta: Int) {
        let count = columns[focusedColumn].rows.count
        guard count > 0 else { return }
        let current = columns[focusedColumn].highlighted ?? (delta > 0 ? -1 : count)
        let next = min(max(current + delta, 0), count - 1)
        setHighlight(column: focusedColumn, row: next, openSubmenu: false)
        reveal(column: focusedColumn, row: next)
    }

    private func stepBack() {
        let parent = focusedColumn - 1
        closeColumns(after: parent)
        focusedColumn = parent
        retargetQuickLook()
    }

    private func activateHighlighted() {
        guard let row = columns[focusedColumn].highlighted else { return }
        if case .item(let url) = columns[focusedColumn].rows[row], columns[focusedColumn].folders.contains(url) {
            openChild(of: focusedColumn, row: row, focus: true)
        } else {
            click(column: focusedColumn, row: row)
        }
    }

    private func typeSelect(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - typeBufferAt > 1 { typeBuffer = "" }
        typeBufferAt = now
        typeBuffer += characters

        let column = columns[focusedColumn]
        let titles = column.rows.map { column.titles[$0] ?? "" }
        if let index = FolderListLayout.typeSelectIndex(titles: titles, query: typeBuffer) {
            setHighlight(column: focusedColumn, row: index, openSubmenu: false)
            reveal(column: focusedColumn, row: index)
        }
        return true
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        let quickLook = FolderQuickLookController.shared
        if quickLook.isShowing(for: self) {
            quickLook.close(owner: self)
        } else if let url = highlightedURL {
            quickLook.show(url, owner: self)
        }
    }

    private func retargetQuickLook() {
        guard let url = highlightedURL else { return }
        FolderQuickLookController.shared.retarget(url, owner: self)
    }

    // MARK: - Click away

    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleClick(event, isOwnApp: true)
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleClick(event, isOwnApp: false)
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleClick(_ event: NSEvent, isOwnApp: Bool) {
        // The click that opened the stack can arrive after we install.
        guard isPresented, event.timestamp > presentedAt else { return }
        let point = NSEvent.mouseLocation
        if columns.contains(where: { $0.screenFrame.contains(point) }) { return }
        if FolderQuickLookController.shared.isShowing(for: self),
           FolderQuickLookController.shared.frame?.contains(point) == true { return }
        // A click on our own tile is the tile's toggle; let it close us.
        if isOwnApp, let anchorView, let window = anchorView.window, event.window === window {
            let tileFrame = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
            if tileFrame.contains(point) { return }
        }
        DispatchQueue.main.async { [weak self] in self?.dismiss() }
    }
}

// MARK: - SwiftUI

private struct FolderListStackView: View {
    @ObservedObject var controller: FolderListStackController

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(controller.columns.enumerated()), id: \.element.id) { index, column in
                FolderListColumnView(controller: controller, columnIndex: index, column: column)
                    .frame(width: column.frameInPanel.width, height: column.frameInPanel.height)
                    .offset(x: column.frameInPanel.minX, y: column.frameInPanel.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FolderListColumnView: View {
    let controller: FolderListStackController
    let columnIndex: Int
    let column: FolderListStackController.Column

    private var coordinateSpace: String { "folder-list-column-\(column.id)" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    switch column.state {
                    case .loading where column.itemCount == 0:
                        placeholder("")
                    case .unreadable:
                        placeholder(String(localized: "Can't read folder contents"))
                    default:
                        if column.itemCount == 0 {
                            placeholder(String(localized: "No visible items"))
                        }
                    }
                    rows
                }
                .padding(.vertical, FolderListLayout.verticalPadding)
            }
            .coordinateSpace(name: coordinateSpace)
            .onReceive(controller.$scrollTarget) { target in
                guard let target, target.column == column.id else { return }
                proxy.scrollTo(target.row)
            }
        }
        .background(FolderListMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            controller.drop(providers, into: column.url)
        }
    }

    private var rows: some View {
        ForEach(Array(column.rows.enumerated()), id: \.element) { index, row in
            if row == .openInFinder {
                Divider()
                    .padding(.horizontal, 10)
                    .frame(height: FolderListLayout.dividerHeight)
            }
            rowView(index: index, row: row)
                .id(row)
        }
    }

    @ViewBuilder
    private func rowView(index: Int, row: FolderListStackController.Row) -> some View {
        let isHighlighted = column.highlighted == index
        let base = FolderListRowView(
            row: row,
            title: column.titles[row] ?? "",
            isFolder: { if case .item(let url) = row { return column.folders.contains(url) } else { return false } }(),
            isHighlighted: isHighlighted
        )
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        controller.reportRowFrame(column: column.id, row: row, frame: geometry.frame(in: .named(coordinateSpace)))
                    }
                    .onChange(of: geometry.frame(in: .named(coordinateSpace))) { _, frame in
                        controller.reportRowFrame(column: column.id, row: row, frame: frame)
                    }
            }
        )
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                controller.pointerMoved(column: columnIndex, row: index, location: location)
            }
        }
        .onTapGesture {
            controller.click(column: columnIndex, row: index)
        }

        if case .item(let url) = row {
            let isFolder = column.folders.contains(url)
            base
                .onDrag { controller.dragProvider(for: url) }
                .onDrop(
                    of: isFolder ? [UTType.fileURL.identifier] : [],
                    isTargeted: isFolder ? Binding(
                        get: { false },
                        set: { controller.springLoad(column: columnIndex, row: index, isTargeted: $0) }
                    ) : nil,
                    perform: { providers in
                        isFolder ? controller.drop(providers, into: url) : false
                    }
                )
        } else {
            base
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: NSFont.systemFontSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(height: FolderListLayout.rowHeight)
    }
}

private struct FolderListRowView: View {
    let row: FolderListStackController.Row
    let title: String
    let isFolder: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: NSFont.systemFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 10)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: FolderListLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHighlighted ? Color.accentColor : Color.clear)
                .padding(.horizontal, 5)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch row {
        case .item(let url):
            Image(nsImage: IconCacheService.shared.previewIcon(forFileURL: url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        case .openInFinder:
            Image(systemName: "folder")
                .font(.system(size: 13))
        }
    }
}

private struct FolderListMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
