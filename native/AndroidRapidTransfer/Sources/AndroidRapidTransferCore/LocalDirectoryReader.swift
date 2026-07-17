import Foundation

actor LocalDirectoryReader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func snapshot(at directory: URL, showsHiddenFiles: Bool) throws -> LocalDirectorySnapshot {
        let keys: [URLResourceKey] = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isDirectoryKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: showsHiddenFiles ? [] : [.skipsHiddenFiles]
        )

        let entries = try urls.map { url in
            let values = try url.resourceValues(forKeys: Set(keys))
            let isDirectory = values.isDirectory == true
            return BrowserEntry(
                id: url.standardizedFileURL.path,
                name: url.lastPathComponent,
                size: isDirectory ? nil : values.fileSize.map(Int64.init),
                modified: values.contentModificationDate,
                isDirectory: isDirectory,
                location: url.standardizedFileURL.path
            )
        }
        let attributes = try fileManager.attributesOfFileSystem(forPath: directory.path)
        let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
        let totalBytes = (attributes[.systemSize] as? NSNumber)?.int64Value
        let capacity: BrowserCapacity? = if let freeBytes, let totalBytes {
            BrowserCapacity(freeBytes: freeBytes, totalBytes: totalBytes)
        } else {
            nil
        }
        return LocalDirectorySnapshot(entries: entries, capacity: capacity)
    }
}

struct LocalDirectorySnapshot {
    let entries: [BrowserEntry]
    let capacity: BrowserCapacity?
}
