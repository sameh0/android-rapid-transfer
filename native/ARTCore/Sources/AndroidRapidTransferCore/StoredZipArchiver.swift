import Foundation

/// The archiver bug reports use unless a caller supplies one.
public enum BugReportArchivers {
    /// The system's own archiver on Apple platforms (`FileCoordinatorArchiver`);
    /// `StoredZipArchiver` elsewhere.
    public static var platformDefault: any BugReportArchiving {
        #if canImport(Darwin)
        FileCoordinatorArchiver()
        #else
        StoredZipArchiver()
        #endif
    }
}

public enum StoredZipArchiverError: Error, Equatable, Sendable {
    /// The archive would need Zip64, which this writer does not produce.
    case tooLarge
    case notADirectory(String)
}

/// Writes a plain zip with every entry stored (no compression): no child
/// process and no dependency, portable to every platform. The directory itself
/// is the top-level entry, like `FileCoordinatorArchiver`'s output. Meant for
/// small bundles such as bug reports; archives past 4 GiB are refused.
public struct StoredZipArchiver: BugReportArchiving {
    public init() {}

    public func archive(directory: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw StoredZipArchiverError.notADirectory(directory.path)
        }
        var entries: [Entry] = []
        try collect(directory, name: directory.lastPathComponent, into: &entries)

        var archive = Data()
        var central = Data()
        for entry in entries {
            let offset = archive.count
            let crc = Self.crc32(entry.data)
            guard entry.data.count < Int(UInt32.max), offset < Int(UInt32.max) else {
                throw StoredZipArchiverError.tooLarge
            }
            let name = Data(entry.name.utf8)
            let (time, date) = Self.dosTimestamp(entry.modified)

            archive.appendLE(UInt32(0x0403_4B50))
            archive.appendLE(UInt16(20))            // version needed to extract
            archive.appendLE(UInt16(0x0800))        // flags: UTF-8 names
            archive.appendLE(UInt16(0))             // method: stored
            archive.appendLE(time)
            archive.appendLE(date)
            archive.appendLE(crc)
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt32(entry.data.count))
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))             // extra field length
            archive.append(name)
            archive.append(entry.data)

            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(0x0314))        // made by: Unix, spec 2.0
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(time)
            central.appendLE(date)
            central.appendLE(crc)
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))             // extra field length
            central.appendLE(UInt16(0))             // comment length
            central.appendLE(UInt16(0))             // disk number start
            central.appendLE(UInt16(0))             // internal attributes
            central.appendLE(entry.externalAttributes)
            central.appendLE(UInt32(offset))
            central.append(name)
        }
        let centralOffset = archive.count
        guard entries.count < Int(UInt16.max),
              centralOffset + central.count < Int(UInt32.max) else {
            throw StoredZipArchiverError.tooLarge
        }
        archive.append(central)
        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0))                 // this disk
        archive.appendLE(UInt16(0))                 // disk with the central directory
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count))
        archive.appendLE(UInt32(centralOffset))
        archive.appendLE(UInt16(0))                 // comment length
        try archive.write(to: destination, options: .atomic)
    }

    private struct Entry {
        let name: String
        let data: Data
        let modified: Date
        let externalAttributes: UInt32
    }

    /// Appends `url` (named `name` in the archive, no trailing slash) and, for
    /// a directory, everything under it in name order.
    private func collect(_ url: URL, name: String, into entries: inout [Entry]) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let modified = attributes[.modificationDate] as? Date ?? Date()
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint32Value
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            let mode = UInt32(0o040000) | (permissions ?? 0o755)
            entries.append(
                Entry(name: name + "/", data: Data(), modified: modified, externalAttributes: mode << 16 | 0x10)
            )
            for child in try fileManager.contentsOfDirectory(atPath: url.path).sorted() {
                try collect(url.appending(path: child), name: name + "/" + child, into: &entries)
            }
        } else if attributes[.type] as? FileAttributeType == .typeRegular {
            let mode = UInt32(0o100000) | (permissions ?? 0o644)
            entries.append(
                Entry(name: name, data: try Data(contentsOf: url), modified: modified, externalAttributes: mode << 16)
            )
        }
        // Symbolic links and special files are skipped.
    }

    /// MS-DOS time and date in local time, clamped to the format's 1980 epoch.
    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(1980, min(2107, parts.year ?? 1980))
        let hour: Int = parts.hour ?? 0, minute: Int = parts.minute ?? 0, second: Int = parts.second ?? 0
        let month: Int = parts.month ?? 1, dayOfMonth: Int = parts.day ?? 1
        let time = UInt16(hour << 11 | minute << 5 | second / 2)
        let day = UInt16((year - 1980) << 9 | month << 5 | dayOfMonth)
        return (time, day)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}
