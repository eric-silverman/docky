//
//  DockBadgeService.swift
//  Docky
//
//  Reads notification badges (the red number on Mail, Messages, etc.) for
//  running apps and republishes them keyed by bundle identifier so tiles can
//  draw their own badge.
//
//  Source of truth: LaunchServices. Apps that badge through the
//  notification system (Messages, WhatsApp) skip LaunchServices, so those
//  come from the hidden system Dock's accessibility tree instead. When
//  Docky restarts the Dock, those badges return once the app updates them.
//

import AppKit
import ApplicationServices
import Combine

@MainActor
final class DockBadgeService: ObservableObject {
    static let shared = DockBadgeService()

    /// Badge text per bundle identifier, e.g. ["com.apple.mail": "5"].
    /// Apps with no badge are absent from the map.
    @Published private(set) var badgesByBundleID: [String: String] = [:]

    /// Nothing notifies us of badge changes, so we poll. Each read is one
    /// LaunchServices lookup per running app.
    private let pollInterval: TimeInterval = 2

    private var timer: Timer?
    private var readTask: Task<Void, Never>?

    private init() {}

    func badge(forBundleIdentifier bundleIdentifier: String) -> String? {
        badgesByBundleID[bundleIdentifier]
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    /// The LaunchServices reads are synchronous XPC (two per app), so they
    /// run off the main thread; on it they stalled the dock for tens of
    /// milliseconds every poll, dropping frames mid-hover.
    private func refresh() {
        guard readTask == nil else { return }
        readTask = Task {
            let newBadges = await Task.detached(priority: .utility) { Self.readBadges() }.value
            readTask = nil
            if newBadges != badgesByBundleID {
                badgesByBundleID = newBadges
            }
        }
    }

    nonisolated private static func readBadges() -> [String: String] {
        var badges: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  let badge = badgeLabel(forProcessIdentifier: app.processIdentifier) else { continue }
            badges[bundleID] = badge
        }
        // Apps that badge through the notification system (Messages,
        // WhatsApp) never write to LaunchServices; only the system Dock
        // gets those, so fill gaps from its accessibility tree.
        badges.merge(systemDockBadges()) { launchServices, _ in launchServices }
        return badges
    }

    /// Badges the (hidden) system Dock is showing, keyed by bundle ID.
    /// Needs Accessibility; returns nothing without it.
    nonisolated private static func systemDockBadges() -> [String: String] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        var badges: [String: String] = [:]
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        for list in axChildren(of: dockElement) {
            for item in axChildren(of: list) {
                guard let label = axValue(item, "AXStatusLabel") as? String,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let url = axValue(item, kAXURLAttribute) as? URL,
                      let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
                badges[bundleID] = label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return badges
    }

    nonisolated private static func axChildren(of element: AXUIElement) -> [AXUIElement] {
        (axValue(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    nonisolated private static func axValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// The badge string the app set (e.g. "5", "•"). Empty / whitespace
    /// means no badge.
    nonisolated private static func badgeLabel(forProcessIdentifier pid: pid_t) -> String? {
        guard let asn = _LSASNCreateWithPid(nil, pid)?.takeRetainedValue(),
              let info = _LSCopyApplicationInformationItem(kLSDefaultSessionID, asn, "StatusLabel" as CFString)?
                .takeRetainedValue() as? [String: Any],
              let label = info["label"] as? String else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
