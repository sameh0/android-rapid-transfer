import Foundation

/// A malformed dataset or container.
public struct PTPDecodingError: Error, Equatable, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "PTP decoding error: \(message)" }
}

/// Little-endian reader over PTP-encoded bytes. Every read is bounds-checked
/// and throws ``PTPDecodingError`` on underflow instead of trapping.
public struct PTPReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public init(_ data: Data) {
        self.init([UInt8](data))
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    private mutating func take(_ count: Int, _ what: @autoclosure () -> String) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else {
            throw PTPDecodingError("underflow reading \(what()): need \(count) byte(s) at offset \(offset), have \(remaining)")
        }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    private mutating func readLE<T: FixedWidthInteger>(_ type: T.Type, _ what: String) throws -> T {
        let slice = try take(MemoryLayout<T>.size, what)
        var value: T = 0
        for (shift, byte) in slice.enumerated() {
            value |= T(truncatingIfNeeded: byte) << (8 * shift)
        }
        return value
    }

    public mutating func u8(_ what: String = "u8") throws -> UInt8 { try readLE(UInt8.self, what) }
    public mutating func u16(_ what: String = "u16") throws -> UInt16 { try readLE(UInt16.self, what) }
    public mutating func u32(_ what: String = "u32") throws -> UInt32 { try readLE(UInt32.self, what) }
    public mutating func u64(_ what: String = "u64") throws -> UInt64 { try readLE(UInt64.self, what) }
    public mutating func i8(_ what: String = "i8") throws -> Int8 { try readLE(Int8.self, what) }
    public mutating func i16(_ what: String = "i16") throws -> Int16 { try readLE(Int16.self, what) }
    public mutating func i32(_ what: String = "i32") throws -> Int32 { try readLE(Int32.self, what) }
    public mutating func i64(_ what: String = "i64") throws -> Int64 { try readLE(Int64.self, what) }

    /// 128-bit value as its 16 raw little-endian bytes.
    public mutating func u128(_ what: String = "u128") throws -> [UInt8] {
        Array(try take(16, what))
    }

    public mutating func raw(_ count: Int, _ what: String = "bytes") throws -> [UInt8] {
        Array(try take(count, what))
    }

    /// PTP array: u32 element count, then the elements.
    public mutating func array<T>(_ what: String, _ element: (inout PTPReader) throws -> T) throws -> [T] {
        let count = Int(try u32("\(what) count"))
        // A corrupt count must fail on underflow, not on a huge allocation.
        guard count <= remaining else {
            throw PTPDecodingError("\(what) count \(count) exceeds remaining \(remaining) byte(s)")
        }
        var result: [T] = []
        result.reserveCapacity(count)
        for _ in 0..<count { result.append(try element(&self)) }
        return result
    }

    public mutating func u16Array(_ what: String = "u16 array") throws -> [UInt16] {
        try array(what) { try $0.u16(what) }
    }

    public mutating func u32Array(_ what: String = "u32 array") throws -> [UInt32] {
        try array(what) { try $0.u32(what) }
    }

    /// PTP string: u8 count of UTF-16 code units *including* the terminating
    /// NUL, then the units little-endian. A count of 0 is the empty string.
    /// A missing terminator is tolerated; surrogate pairs are decoded.
    public mutating func string(_ what: String = "string") throws -> String {
        let count = Int(try u8("\(what) length"))
        if count == 0 { return "" }
        let raw = try take(count * 2, what)
        var units: [UInt16] = []
        units.reserveCapacity(count)
        var index = raw.startIndex
        while index < raw.endIndex {
            units.append(UInt16(raw[index]) | UInt16(raw[index + 1]) << 8)
            index += 2
        }
        // Drop the terminator (and anything a sloppy device put after it).
        if let nul = units.firstIndex(of: 0) { units.removeSubrange(nul...) }
        return String(decoding: units, as: UTF16.self)
    }
}

/// Little-endian writer producing PTP-encoded bytes.
public struct PTPWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var data: Data { Data(bytes) }

    private mutating func writeLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
    }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { writeLE(v) }
    public mutating func u32(_ v: UInt32) { writeLE(v) }
    public mutating func u64(_ v: UInt64) { writeLE(v) }
    public mutating func i8(_ v: Int8) { writeLE(v) }
    public mutating func i16(_ v: Int16) { writeLE(v) }
    public mutating func i32(_ v: Int32) { writeLE(v) }
    public mutating func i64(_ v: Int64) { writeLE(v) }
    public mutating func raw(_ v: [UInt8]) { bytes.append(contentsOf: v) }

    public mutating func u16Array(_ values: [UInt16]) {
        u32(UInt32(values.count))
        values.forEach { u16($0) }
    }

    public mutating func u32Array(_ values: [UInt32]) {
        u32(UInt32(values.count))
        values.forEach { u32($0) }
    }

    /// Longest PTP string: 255 code units including the terminator.
    public static let maxStringUnits = 254

    /// Writes a PTP string. Empty is a single 0 byte. Throws when the string
    /// needs more than 254 UTF-16 code units (255 with the terminator).
    public mutating func string(_ s: String) throws {
        if s.isEmpty {
            u8(0)
            return
        }
        let units = Array(s.utf16)
        guard units.count <= Self.maxStringUnits else {
            throw PTPDecodingError("string of \(units.count) UTF-16 units exceeds the PTP limit of \(Self.maxStringUnits)")
        }
        u8(UInt8(units.count + 1))
        units.forEach { u16($0) }
        u16(0)
    }
}

/// PTP DateTime strings: "YYYYMMDDThhmmss[.s][Z|±hhmm]".
public enum PTPDateTime {
    /// Parses leniently: trailing dots (Samsung) and "Z" (Sailfish) are
    /// tolerated, a numeric zone (Lumia) is honoured, and a time without a
    /// zone is interpreted as UTC. Returns nil for "" or unparsable input.
    public static func parse(_ raw: String) -> Date? {
        var s = raw
        while s.hasSuffix(".") { s.removeLast() }
        while s.hasSuffix("Z") { s.removeLast() }
        guard s.count >= 15 else { return nil }
        let chars = Array(s)
        guard chars[8] == "T" else { return nil }
        func num(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let year = num(0..<4), let month = num(4..<6), let day = num(6..<8),
              let hour = num(9..<11), let minute = num(11..<13), let second = num(13..<15)
        else { return nil }

        var rest = chars[15...]
        // Optional tenths of a second.
        if rest.first == "." {
            rest = rest.dropFirst()
            while let c = rest.first, c.isNumber { rest = rest.dropFirst() }
        }
        var offsetSeconds = 0
        if let sign = rest.first, sign == "+" || sign == "-" {
            let zone = Array(rest.dropFirst())
            guard zone.count == 4, let hh = Int(String(zone[0..<2])), let mm = Int(String(zone[2..<4])) else { return nil }
            offsetSeconds = (hh * 3600 + mm * 60) * (sign == "-" ? -1 : 1)
        } else if !rest.isEmpty {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetSeconds)!
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day
        else { return nil }
        return date
    }

    /// Formats as "YYYYMMDDThhmmss" in UTC.
    public static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
