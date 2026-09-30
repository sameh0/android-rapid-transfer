import Foundation

extension FileManager {
    /// Replaces the item at `destination` with the item at `source`, which is
    /// consumed. On Apple platforms this is `replaceItemAt(_:withItemAt:)`.
    ///
    /// The Foundation on other platforms fails that call whenever the
    /// destination exists (it reports the destination as missing), so there the
    /// old item is renamed aside next to the destination, the new one renamed
    /// into place and the old one deleted; if the second rename fails the old
    /// item is put back. The old item never leaves its directory; the new one
    /// is copied if it comes from another filesystem, as `moveItem` does.
    func replaceItemCore(at destination: URL, withItemAt source: URL) throws {
        #if canImport(Darwin)
        _ = try replaceItemAt(destination, withItemAt: source)
        #else
        guard fileExists(atPath: destination.path) else {
            try moveItem(at: source, to: destination)
            return
        }
        let backup = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).replaced-\(UUID().uuidString)")
        try moveItem(at: destination, to: backup)
        do {
            try moveItem(at: source, to: destination)
        } catch {
            try? moveItem(at: backup, to: destination)
            throw error
        }
        try? removeItem(at: backup)
        #endif
    }
}
