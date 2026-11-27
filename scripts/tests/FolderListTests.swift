// Assert-based tests for FolderListLayout and FolderItemInfo.
// Run: scripts/test-folder-list.sh

import CoreGraphics
import Foundation

@main
struct FolderListTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition {
            failures += 1
            print("FAIL (line \(line)): \(message)")
        }
    }

    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let size = CGSize(width: 300, height: 200)

        // Root placement per dock side.
        let bottomTile = CGRect(x: 700, y: 10, width: 60, height: 60)
        let above = FolderListLayout.columnFrames(anchor: bottomTile, side: .above, sizes: [size], openerRowTops: [], visible: screen)[0]
        check(above.minY == bottomTile.maxY + FolderListLayout.tileGap, "above: sits over the tile")
        check(above.midX == bottomTile.midX, "above: centred on the tile")

        let topTile = CGRect(x: 700, y: 870, width: 60, height: 60)
        let below = FolderListLayout.columnFrames(anchor: topTile, side: .below, sizes: [size], openerRowTops: [], visible: screen)[0]
        check(below.maxY == topTile.minY - FolderListLayout.tileGap, "below: hangs under the tile")

        let leftTile = CGRect(x: 4, y: 400, width: 60, height: 60)
        let right = FolderListLayout.columnFrames(anchor: leftTile, side: .right, sizes: [size], openerRowTops: [], visible: screen)[0]
        check(right.minX == leftTile.maxX + FolderListLayout.tileGap, "right: beside a left dock")

        let rightTile = CGRect(x: 1448, y: 400, width: 60, height: 60)
        let left = FolderListLayout.columnFrames(anchor: rightTile, side: .left, sizes: [size], openerRowTops: [], visible: screen)[0]
        check(left.maxX == rightTile.minX - FolderListLayout.tileGap, "left: beside a right dock")

        // Clamping at screen edges.
        let cornerTile = CGRect(x: 0, y: 10, width: 60, height: 60)
        let clamped = FolderListLayout.columnFrames(anchor: cornerTile, side: .above, sizes: [size], openerRowTops: [], visible: screen)[0]
        check(clamped.minX == screen.minX + FolderListLayout.screenMargin, "root clamps to the left screen edge")
        let tall = FolderListLayout.columnFrames(anchor: bottomTile, side: .above, sizes: [CGSize(width: 300, height: 2000)], openerRowTops: [], visible: screen)[0]
        check(tall.height <= screen.height - 2 * FolderListLayout.screenMargin, "tall column fits the screen")
        check(tall.minY >= screen.minY && tall.maxY <= screen.maxY, "tall column stays on screen")

        // Cascading.
        let rowTop: CGFloat = above.maxY - 40
        let two = FolderListLayout.columnFrames(anchor: bottomTile, side: .above, sizes: [size, size], openerRowTops: [rowTop], visible: screen)
        check(two[1].minX == two[0].maxX, "child opens to the right")
        check(two[1].maxY == rowTop + FolderListLayout.verticalPadding, "child's first row lines up with the opener row")

        let edgeTile = CGRect(x: 1300, y: 10, width: 60, height: 60)
        let flipped = FolderListLayout.columnFrames(anchor: edgeTile, side: .above, sizes: [size, size, size], openerRowTops: [700, 700], visible: screen)
        check(flipped[1].maxX == flipped[0].minX, "child flips left when there's no room on the right")
        check(flipped[2].maxX == flipped[1].minX, "flipped direction sticks for deeper columns")

        let rightDock = FolderListLayout.columnFrames(anchor: rightTile, side: .left, sizes: [size, size], openerRowTops: [500], visible: screen)
        check(rightDock[1].maxX == rightDock[0].minX, "right dock cascades leftwards")

        let secondDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let tileOnSecond = CGRect(x: -1000, y: 10, width: 60, height: 60)
        let onSecond = FolderListLayout.columnFrames(anchor: tileOnSecond, side: .above, sizes: [size, size], openerRowTops: [300], visible: secondDisplay)
        check(onSecond.allSatisfy { secondDisplay.contains($0) }, "columns stay on a display with a negative origin")

        let lowRow = FolderListLayout.columnFrames(anchor: bottomTile, side: .above, sizes: [size, CGSize(width: 300, height: 600)], openerRowTops: [120], visible: screen)
        check(lowRow[1].minY >= screen.minY + FolderListLayout.screenMargin, "child near the bottom is pushed up to fit")

        // Sizes.
        check(FolderListLayout.columnWidth(longestTitleWidth: 10) == FolderListLayout.minWidth, "width has a minimum")
        check(FolderListLayout.columnWidth(longestTitleWidth: 5000) == FolderListLayout.maxWidth, "width has a maximum")
        check(FolderListLayout.columnWidth(longestTitleWidth: 200) == 200 + FolderListLayout.rowChromeWidth, "width follows the longest name")
        check(FolderListLayout.columnHeight(rowCount: 3, hasDivider: true, visibleHeight: 944) == 3 * 22 + 11 + 10, "height for 3 rows + divider")
        check(FolderListLayout.columnHeight(rowCount: 0, hasDivider: false, visibleHeight: 944) == 22 + 10, "empty column keeps one row")
        check(FolderListLayout.columnHeight(rowCount: 500, hasDivider: false, visibleHeight: 944) == 944 - 12, "long column capped to the screen")

        // Type-select.
        let titles = ["Applications", "Downloads", "Résumé.pdf", "desktop notes"]
        check(FolderListLayout.typeSelectIndex(titles: titles, query: "do") == 1, "prefix match")
        check(FolderListLayout.typeSelectIndex(titles: titles, query: "DE") == 3, "case-insensitive")
        check(FolderListLayout.typeSelectIndex(titles: titles, query: "resu") == 2, "diacritic-insensitive")
        check(FolderListLayout.typeSelectIndex(titles: titles, query: "ownl") == nil, "prefix only, not substring")
        check(FolderListLayout.typeSelectIndex(titles: titles, query: "") == nil, "empty query matches nothing")

        // Safe triangle.
        let child = CGRect(x: 300, y: 100, width: 200, height: 300)
        let origin = CGPoint(x: 250, y: 250)
        check(FolderListLayout.isInSafeTriangle(point: CGPoint(x: 280, y: 260), origin: origin, child: child), "moving towards the submenu is safe")
        check(!FolderListLayout.isInSafeTriangle(point: CGPoint(x: 240, y: 250), origin: origin, child: child), "moving away is not safe")
        check(!FolderListLayout.isInSafeTriangle(point: CGPoint(x: 290, y: 450), origin: origin, child: child), "moving past the submenu's top is not safe")
        let leftChild = CGRect(x: 0, y: 100, width: 200, height: 300)
        check(FolderListLayout.isInSafeTriangle(point: CGPoint(x: 220, y: 240), origin: origin, child: leftChild), "works for submenus on the left")

        // FolderItemInfo.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("docky-folder-list-tests-\(UUID().uuidString)")
        let folder = temp.appendingPathComponent("Folder")
        let package = temp.appendingPathComponent("Thing.app")
        let file = temp.appendingPathComponent("note.txt")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data("hi".utf8))
        check(FolderItemInfo.isNavigableFolder(folder), "a directory is navigable")
        check(!FolderItemInfo.isNavigableFolder(package), "a package (.app) is not navigable")
        check(!FolderItemInfo.isNavigableFolder(file), "a file is not navigable")
        check(!FolderItemInfo.isNavigableFolder(temp.appendingPathComponent("missing")), "a missing path is not navigable")
        check(FolderItemInfo.displayName(for: temp.appendingPathComponent("missing.txt")) == "missing.txt", "display name falls back to the file name")

        let moved = temp.appendingPathComponent("move-me.txt")
        FileManager.default.createFile(atPath: moved.path, contents: Data())
        FolderItemInfo.moveItems([moved, folder.appendingPathComponent("already-here")], into: folder)
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("move-me.txt").path), "moveItems moves into the folder")
        check(!FileManager.default.fileExists(atPath: moved.path), "moveItems removes the source")
        let nested = folder.appendingPathComponent("Inner")
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FolderItemInfo.moveItems([folder], into: nested)
        FolderItemInfo.moveItems([folder], into: folder)
        check(FileManager.default.fileExists(atPath: folder.path), "a folder is never moved into itself or its subfolder")
        check(!FileManager.default.fileExists(atPath: nested.appendingPathComponent("Folder").path), "no recursive copy into a subfolder")
        check(FolderItemInfo.isSameVolume(folder, nested), "same volume detected")
        check(!FolderItemInfo.isSameVolume(folder, temp.appendingPathComponent("missing")), "unknown volume counts as different (copy)")
        try? FileManager.default.removeItem(at: temp)

        if failures == 0 {
            print("All folder list tests passed.")
            exit(0)
        }
        print("\(failures) failure(s).")
        exit(1)
    }
}
