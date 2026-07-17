import Foundation

public protocol LocalFileOperationService: Sendable {
    func createDirectory(at url: URL) async throws
    func renameItem(at sourceURL: URL, to destinationURL: URL) async throws
    func trashItem(at url: URL) async throws
}

public actor FileManagerLocalFileOperationService: LocalFileOperationService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createDirectory(at url: URL) async throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public func renameItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    public func trashItem(at url: URL) async throws {
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
    }
}
