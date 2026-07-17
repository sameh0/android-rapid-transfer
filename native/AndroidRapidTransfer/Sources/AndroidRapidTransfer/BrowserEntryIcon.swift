import AndroidRapidTransferCore
import AppKit
import UniformTypeIdentifiers

/// The icon Finder shows for an entry's kind: a folder, or the file type its
/// name extension implies. Device entries have no file on this Mac, so both
/// panes go by type rather than by path, and look the same.
@MainActor
enum BrowserEntryIcon {
    /// Grid icons sit in a fixed square so every cell's icon and label line
    /// up, whatever the artwork's own proportions.
    static let gridSize: CGFloat = 64
    static let listSize: CGFloat = 16

    private static var cache: [String: NSImage] = [:]

    static func image(for entry: BrowserEntry) -> NSImage {
        let type = contentType(for: entry)
        if let cached = cache[type.identifier] {
            return cached
        }
        let image = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = image
        return image
    }

    nonisolated static func contentType(for entry: BrowserEntry) -> UTType {
        if entry.isDirectory {
            return .folder
        }
        let pathExtension = (entry.name as NSString).pathExtension
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension) else {
            return .data
        }
        return type
    }
}
