import Foundation

public enum TransferStagingError: Error, CustomStringConvertible, Sendable {
    case missingDownloadedItem(String)

    public var description: String {
        switch self {
        case let .missingDownloadedItem(path):
            "The transfer completed without creating the expected item at \(path)"
        }
    }
}

public enum TransferCompletionAction: Equatable, Sendable {
    case moveStagedItem(sourcePath: String, destinationPath: String, replaceExisting: Bool)
}

public enum TransferStaging {
    public static func makeDirectory(
        appropriateFor destination: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        let directory = replacementDirectory.deletingLastPathComponent()
            .appending(path: "\(AppIdentity.fileNamePrefix)-Staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.moveItem(at: replacementDirectory, to: directory)
            return directory
        } catch {
            try? fileManager.removeItem(at: replacementDirectory)
            throw error
        }
    }

    public static func copyForUpload(
        source: URL,
        named name: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let stagedURL = directory.appending(path: name)
        try fileManager.copyItem(at: source, to: stagedURL)
        return stagedURL
    }

    public static func finish(
        _ action: TransferCompletionAction,
        fileManager: FileManager = .default
    ) throws {
        switch action {
        case let .moveStagedItem(sourcePath, destinationPath, replaceExisting):
            let source = URL(fileURLWithPath: sourcePath)
            let destination = URL(fileURLWithPath: destinationPath)
            guard fileManager.fileExists(atPath: source.path) else {
                throw TransferStagingError.missingDownloadedItem(source.path)
            }
            if replaceExisting, fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: source)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    public static func removeDirectory(
        at path: String,
        fileManager: FileManager = .default
    ) throws {
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }
}

public protocol TransferStagingService: Sendable {
    func makeDirectory(appropriateFor destination: URL) async throws -> URL
    func copyForUpload(source: URL, named name: String, in directory: URL) async throws -> URL
    func removeDirectory(at path: String) async throws
}

public actor FileManagerTransferStagingService: TransferStagingService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func makeDirectory(appropriateFor destination: URL) throws -> URL {
        try Task.checkCancellation()
        return try TransferStaging.makeDirectory(
            appropriateFor: destination,
            fileManager: fileManager
        )
    }

    public func copyForUpload(
        source: URL,
        named name: String,
        in directory: URL
    ) throws -> URL {
        try Task.checkCancellation()
        let stagedURL = try TransferStaging.copyForUpload(
            source: source,
            named: name,
            in: directory,
            fileManager: fileManager
        )
        try Task.checkCancellation()
        return stagedURL
    }

    public func removeDirectory(at path: String) throws {
        try TransferStaging.removeDirectory(at: path, fileManager: fileManager)
    }
}
