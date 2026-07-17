import Foundation

/// Stateless, so a struct: actor isolation would serialize bulk local copies
/// that `TransferViewModel` deliberately runs in parallel. `FileManager` is
/// documented as safe to call from multiple threads when no delegate is set,
/// and this service never sets one.
public struct LocalFileCopyService: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func copy(source: URL, to destination: URL, replaceExisting: Bool) throws {
        guard replaceExisting else {
            try fileManager.copyItem(at: source, to: destination)
            return
        }

        let temporary = destination.deletingLastPathComponent().appending(
            path: ".\(AppIdentity.fileNamePrefix)-Copy-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
