import Foundation

public struct BrowserCapacity: Equatable, Sendable {
    public let freeBytes: Int64
    public let totalBytes: Int64

    public init(freeBytes: Int64, totalBytes: Int64) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }

    public var formattedFreeBytes: String {
        freeBytes.formatted(.byteCount(style: .file))
    }

    public var formattedTotalBytes: String {
        totalBytes.formatted(.byteCount(style: .file))
    }
}
