import Foundation
import MTPKit

public struct DeviceStorage: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let totalBytes: Int64?
    public let freeBytes: Int64?

    /// A storage as the browser shows it. A blank description falls back to a
    /// generic name; a capacity of 0 means the device did not report one.
    public init(storage: StorageInfo, index: Int) {
        id = storage.id
        let description = storage.storageDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        name = description.isEmpty ? "Storage \(index + 1)" : storage.storageDescription
        if storage.maxCapacity > 0 {
            totalBytes = Int64(clamping: storage.maxCapacity)
            freeBytes = Int64(clamping: storage.freeSpaceInBytes)
        } else {
            totalBytes = nil
            freeBytes = nil
        }
    }

    public init(
        id: UInt32,
        name: String,
        totalBytes: Int64? = nil,
        freeBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public var capacitySummary: String? {
        guard let totalBytes, let freeBytes else { return nil }
        let free = freeBytes.formatted(.byteCount(style: .file))
        let total = totalBytes.formatted(.byteCount(style: .file))
        return "\(free) free of \(total)"
    }
}
