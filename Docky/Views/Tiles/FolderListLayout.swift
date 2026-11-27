//
//  FolderListLayout.swift
//  Docky
//
//  Pure geometry and matching for the folder List stack. No AppKit window
//  types, so scripts/test-folder-list.sh can compile and test it on its own.
//
//  Screen coordinates throughout (origin bottom-left, y up), like NSWindow.
//
//        child columns cascade sideways from the highlighted row:
//
//        ┌──────────┐┌──────────┐
//        │ Root     ││ Sub      │   column 0 is anchored to the tile,
//        │ ▶ Folder ├┘ ...      │   column n+1 starts at the row in
//        │   File   │└──────────┘   column n that opened it.
//        └────┬─────┘
//           [tile]
//

import CoreGraphics
import Foundation

enum FolderListLayout {
    static let rowHeight: CGFloat = 22
    static let verticalPadding: CGFloat = 5
    static let dividerHeight: CGFloat = 11
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 480
    /// Icon (16) + gaps (8 + 8) + chevron (10) + row insets (2 × 10).
    static let rowChromeWidth: CGFloat = 62
    static let tileGap: CGFloat = 8
    static let screenMargin: CGFloat = 6

    /// Which side of the tile the stack opens on (the dock's inward side).
    enum Side: Equatable {
        case above, below, left, right
    }

    static func columnWidth(longestTitleWidth: CGFloat) -> CGFloat {
        min(max(ceil(longestTitleWidth) + rowChromeWidth, minWidth), maxWidth)
    }

    /// Height for `rowCount` rows (+ an optional divider), capped to what fits
    /// on screen; longer columns scroll.
    static func columnHeight(rowCount: Int, hasDivider: Bool, visibleHeight: CGFloat) -> CGFloat {
        let content = CGFloat(max(rowCount, 1)) * rowHeight
            + (hasDivider ? dividerHeight : 0)
            + verticalPadding * 2
        return min(content, visibleHeight - screenMargin * 2)
    }

    /// Screen frames for each column.
    /// - `sizes`: column sizes, root first.
    /// - `openerRowTops`: for column i ≥ 1, the screen-space top (maxY) of the
    ///   row in column i-1 that opened it. `openerRowTops.count == sizes.count - 1`.
    static func columnFrames(
        anchor: CGRect,
        side: Side,
        sizes: [CGSize],
        openerRowTops: [CGFloat],
        visible: CGRect
    ) -> [CGRect] {
        guard let rootSize = sizes.first else { return [] }
        var frames = [clamp(rootFrame(anchor: anchor, side: side, size: rootSize), to: visible)]

        // Cascade direction: rightwards unless the dock is on the right; flip
        // when the next column doesn't fit, and keep the new direction.
        var goingRight = side != .left
        for (index, size) in sizes.enumerated().dropFirst() {
            let parent = frames[index - 1]
            let rowTop = index - 1 < openerRowTops.count ? openerRowTops[index - 1] : parent.maxY
            // Align the child's first row with the opener row (padding above it).
            let top = rowTop + verticalPadding
            if goingRight, parent.maxX + size.width > visible.maxX - screenMargin {
                goingRight = false
            } else if !goingRight, parent.minX - size.width < visible.minX + screenMargin {
                goingRight = true
            }
            let x = goingRight ? parent.maxX : parent.minX - size.width
            let frame = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
            frames.append(clamp(frame, to: visible))
        }
        return frames
    }

    static func rootFrame(anchor: CGRect, side: Side, size: CGSize) -> CGRect {
        switch side {
        case .above:
            return CGRect(x: anchor.midX - size.width / 2, y: anchor.maxY + tileGap, width: size.width, height: size.height)
        case .below:
            return CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - tileGap - size.height, width: size.width, height: size.height)
        case .right:
            return CGRect(x: anchor.maxX + tileGap, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        case .left:
            return CGRect(x: anchor.minX - tileGap - size.width, y: anchor.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let inset = visible.insetBy(dx: screenMargin, dy: screenMargin)
        var result = frame
        result.size.width = min(frame.width, inset.width)
        result.size.height = min(frame.height, inset.height)
        result.origin.x = min(max(frame.minX, inset.minX), inset.maxX - result.width)
        result.origin.y = min(max(frame.minY, inset.minY), inset.maxY - result.height)
        return result
    }

    /// Index of the first title starting with `query` (case- and
    /// diacritic-insensitive), or nil.
    static func typeSelectIndex(titles: [String], query: String) -> Int? {
        guard !query.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        return titles.firstIndex { $0.range(of: query, options: options) != nil }
    }

    /// Menu "safe triangle": while the pointer travels from `origin` (where it
    /// left the opener row) towards the open child column, `point` stays inside
    /// the triangle formed by `origin` and the child's near edge, and the
    /// submenu shouldn't switch.
    static func isInSafeTriangle(point: CGPoint, origin: CGPoint, child: CGRect) -> Bool {
        let nearX = origin.x <= child.midX ? child.minX : child.maxX
        let a = origin
        let b = CGPoint(x: nearX, y: child.maxY)
        let c = CGPoint(x: nearX, y: child.minY)
        func sign(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = sign(point, a, b)
        let d2 = sign(point, b, c)
        let d3 = sign(point, c, a)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }
}
