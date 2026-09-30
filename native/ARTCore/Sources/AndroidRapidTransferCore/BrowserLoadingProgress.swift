import Foundation

/// What a pane is opening while it loads, for the loading indicator: the
/// folder, and once the device has said how many items it holds, how far the
/// listing has got. Presentation only; it never affects what is loaded.
public struct BrowserLoadingProgress: Equatable, Sendable {
    /// The folder being opened.
    public let path: String
    /// Items in the folder, once known.
    public let itemCount: Int?
    /// How much of the folder has been read, 0...1, once known.
    public let fractionCompleted: Double?

    public init(path: String, itemCount: Int? = nil, fractionCompleted: Double? = nil) {
        self.path = path
        self.itemCount = itemCount
        self.fractionCompleted = fractionCompleted.map { min(max($0, 0), 1) }
    }

    /// The folder's own name, or nil at a storage root.
    public var folderName: String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Items read so far, derived from the fraction so it ticks up while the
    /// device reports progress.
    public var itemsRead: Int? {
        guard let itemCount, let fractionCompleted else { return nil }
        return min(itemCount, Int((Double(itemCount) * fractionCompleted).rounded()))
    }
}
