import Foundation

/// The 12-byte header of every USB bulk container.
public struct PTPContainerHeader: Equatable, Sendable {
    public static let size = 12
    /// Data-phase length marker meaning "more than 4 GB; read until a short packet".
    public static let unknownLength: UInt32 = 0xFFFF_FFFF

    public var length: UInt32
    public var type: UInt16
    public var code: UInt16
    public var transactionID: UInt32

    public init(length: UInt32, type: UInt16, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.type = type
        self.code = code
        self.transactionID = transactionID
    }

    public init(length: UInt32, type: PTPContainerType, code: UInt16, transactionID: UInt32) {
        self.init(length: length, type: type.rawValue, code: code, transactionID: transactionID)
    }

    public var containerType: PTPContainerType? { PTPContainerType(rawValue: type) }

    public func encode(into writer: inout PTPWriter) {
        writer.u32(length)
        writer.u16(type)
        writer.u16(code)
        writer.u32(transactionID)
    }

    public var bytes: [UInt8] {
        var writer = PTPWriter()
        encode(into: &writer)
        return writer.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> PTPContainerHeader {
        var reader = PTPReader(bytes)
        return try decode(&reader)
    }

    public static func decode(_ reader: inout PTPReader) throws -> PTPContainerHeader {
        PTPContainerHeader(
            length: try reader.u32("container length"),
            type: try reader.u16("container type"),
            code: try reader.u16("container code"),
            transactionID: try reader.u32("container transaction id")
        )
    }
}

/// A command container: operation code plus up to five parameters.
public struct PTPCommand: Equatable, Sendable {
    public static let maxParameters = 5

    public var code: UInt16
    public var transactionID: UInt32
    public var parameters: [UInt32]

    public init(code: UInt16, transactionID: UInt32, parameters: [UInt32] = []) {
        precondition(parameters.count <= Self.maxParameters, "a PTP command carries at most 5 parameters")
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    public var bytes: [UInt8] {
        var writer = PTPWriter()
        PTPContainerHeader(
            length: UInt32(PTPContainerHeader.size + 4 * parameters.count),
            type: .command, code: code, transactionID: transactionID
        ).encode(into: &writer)
        parameters.forEach { writer.u32($0) }
        return writer.bytes
    }

    public static func decode(_ bytes: [UInt8]) throws -> PTPCommand {
        var reader = PTPReader(bytes)
        let header = try PTPContainerHeader.decode(&reader)
        guard header.containerType == .command else {
            throw PTPDecodingError("container type \(header.type) is not a command")
        }
        let params = try parameters(header: header, reader: &reader, available: bytes.count)
        return PTPCommand(code: header.code, transactionID: header.transactionID, parameters: params)
    }

    static func parameters(header: PTPContainerHeader, reader: inout PTPReader, available: Int) throws -> [UInt32] {
        let length = Int(header.length)
        guard length >= PTPContainerHeader.size else {
            throw PTPDecodingError("container length \(length) is shorter than its header")
        }
        guard length <= available else {
            throw PTPDecodingError("container declares \(length) byte(s) but only \(available) arrived")
        }
        // At most five parameters are defined; anything beyond (padding from a
        // sloppy device) is ignored rather than failing the transaction.
        let count = min((length - PTPContainerHeader.size) / 4, maxParameters)
        return try (0..<count).map { _ in try reader.u32("parameter") }
    }
}

/// A response container: response code plus up to five parameters.
public struct PTPResponse: Equatable, Sendable {
    public var code: UInt16
    public var transactionID: UInt32
    public var parameters: [UInt32]

    public init(code: UInt16, transactionID: UInt32, parameters: [UInt32] = []) {
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    public var isOK: Bool { code == PTPResponseCode.ok }

    public var bytes: [UInt8] {
        var writer = PTPWriter()
        PTPContainerHeader(
            length: UInt32(PTPContainerHeader.size + 4 * parameters.count),
            type: .response, code: code, transactionID: transactionID
        ).encode(into: &writer)
        parameters.forEach { writer.u32($0) }
        return writer.bytes
    }

    /// Decodes a response container from the start of `bytes`. Trailing bytes
    /// beyond the declared length are ignored.
    public static func decode(_ bytes: [UInt8]) throws -> PTPResponse {
        var reader = PTPReader(bytes)
        let header = try PTPContainerHeader.decode(&reader)
        guard header.containerType == .response else {
            throw PTPDecodingError("container type \(header.type) (code 0x\(String(header.code, radix: 16))) where a response was expected")
        }
        let params = try PTPCommand.parameters(header: header, reader: &reader, available: bytes.count)
        return PTPResponse(code: header.code, transactionID: header.transactionID, parameters: params)
    }
}

/// An event container read from the interrupt endpoint.
public struct PTPEvent: Equatable, Sendable {
    public var code: UInt16
    public var transactionID: UInt32
    public var parameters: [UInt32]

    public static func decode(_ bytes: [UInt8]) throws -> PTPEvent {
        var reader = PTPReader(bytes)
        let header = try PTPContainerHeader.decode(&reader)
        guard header.containerType == .event else {
            throw PTPDecodingError("container type \(header.type) is not an event")
        }
        let params = try PTPCommand.parameters(header: header, reader: &reader, available: bytes.count)
        return PTPEvent(code: header.code, transactionID: header.transactionID, parameters: params)
    }
}
