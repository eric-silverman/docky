//
//  FolderItemInfo.swift
//  Docky
//
//  File facts shared by the folder grid, List stack and fan. Foundation
//  only, so scripts/test-folder-list.sh can test it without the app.
//

import Foundation
import UniformTypeIdentifiers

enum FolderItemInfo {
    /// A folder you can open as a submenu: a directory that isn't a package
    /// (apps, bundles and the like open as files).
    static func isNavigableFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    static func displayName(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
    }

    static func dragItemProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = displayName(for: url)
        return provider
    }

    /// Moves dropped file URLs into `destination`, copying when a move fails
    /// (e.g. across volumes). Skips items already in that folder. Calls
    /// `completion` on the main queue.
    static func moveDroppedFiles(
        providers: [NSItemProvider],
        into destination: URL,
        completion: @escaping () -> Void
    ) {
        let typeID = UTType.fileURL.identifier
        let group = DispatchGroup()
        var collected: [URL] = []
        let queue = DispatchQueue(label: "docky.folder.drop")

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(typeID) else { continue }
            group.enter()
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                defer { group.leave() }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                queue.sync { collected.append(url) }
            }
        }

        group.notify(queue: .main) {
            moveItems(collected, into: destination)
            completion()
        }
    }

    /// Like Finder: moves within a volume, copies across volumes (a move
    /// there would delete the source). Never drops a folder into itself.
    static func moveItems(_ sources: [URL], into destination: URL) {
        let destinationPath = destination.standardizedFileURL.path
        for source in sources {
            let sourcePath = source.standardizedFileURL.path
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard target.standardizedFileURL != source.standardizedFileURL,
                  destinationPath != sourcePath,
                  !destinationPath.hasPrefix(sourcePath + "/") else { continue }
            if isSameVolume(source, destination) {
                try? FileManager.default.moveItem(at: source, to: target)
            } else {
                try? FileManager.default.copyItem(at: source, to: target)
            }
        }
    }

    static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let volumeA = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let volumeB = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else {
            return false // unknown: copy, which never loses the source
        }
        return volumeA.isEqual(volumeB)
    }
}
