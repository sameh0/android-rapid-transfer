import Foundation
import XCTest
@testable import SwiftMTP

final class PTPCodecTests: XCTestCase {
    // MARK: Containers

    func testCommandEncodingIsLittleEndianHeaderPlusParameters() {
        let command = PTPCommand(code: 0x1007, transactionID: 0x0102_0304, parameters: [0x10001, 0, 0xFFFF_FFFF])
        XCTAssertEqual(command.bytes, [
            24, 0, 0, 0, 1, 0, 0x07, 0x10, 0x04, 0x03, 0x02, 0x01,
            0x01, 0x00, 0x01, 0x00, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF
        ])
        XCTAssertEqual(try PTPCommand.decode(command.bytes), command)
    }

    func testHeaderRoundTrip() throws {
        let header = PTPContainerHeader(length: 0xFFFF_FFFF, type: .data, code: 0x1009, transactionID: 42)
        XCTAssertEqual(try PTPContainerHeader.decode(header.bytes), header)
        XCTAssertEqual(header.containerType, .data)
    }

    func testResponseDecodeWithParametersAndTrailingBytes() throws {
        let response = PTPResponse(code: 0x2001, transactionID: 9, parameters: [1, 2, 3])
        XCTAssertEqual(try PTPResponse.decode(response.bytes + [0xAA, 0xBB]), response)
        XCTAssertTrue(response.isOK)
    }

    func testResponseIgnoresParametersBeyondFive() throws {
        var w = PTPWriter()
        PTPContainerHeader(length: 12 + 24, type: .response, code: 0x2001, transactionID: 1).encode(into: &w)
        (1...6).forEach { w.u32(UInt32($0)) }
        XCTAssertEqual(try PTPResponse.decode(w.bytes).parameters, [1, 2, 3, 4, 5])
    }

    func testResponseRejectsWrongTypeAndTruncation() {
        let data = PTPContainerHeader(length: 12, type: .data, code: 0x1001, transactionID: 0).bytes
        XCTAssertThrowsError(try PTPResponse.decode(data))
        let truncated = PTPContainerHeader(length: 20, type: .response, code: 0x2001, transactionID: 0).bytes
        XCTAssertThrowsError(try PTPResponse.decode(truncated))
        XCTAssertThrowsError(try PTPResponse.decode([1, 2, 3]))
    }

    // MARK: Strings

    func testEmptyStringIsSingleZeroByte() throws {
        var w = PTPWriter()
        try w.string("")
        XCTAssertEqual(w.bytes, [0])
        var r = PTPReader([0])
        XCTAssertEqual(try r.string(), "")
        XCTAssertTrue(r.isAtEnd)
    }

    func testStringCountIncludesTerminator() throws {
        var w = PTPWriter()
        try w.string("Ab")
        XCTAssertEqual(w.bytes, [3, 0x41, 0, 0x62, 0, 0, 0])
        var r = PTPReader(w.bytes)
        XCTAssertEqual(try r.string(), "Ab")
        XCTAssertTrue(r.isAtEnd)
    }

    func testStringWithoutTerminatorIsTolerated() throws {
        var r = PTPReader([2, 0x48, 0, 0x69, 0, 0xEE])
        XCTAssertEqual(try r.string(), "Hi")
        XCTAssertEqual(r.remaining, 1)
    }

    func testStringNonASCIIAndSurrogatePairsRoundTrip() throws {
        let value = "Fotos-ÄÖ-日本-😀.jpg"
        var w = PTPWriter()
        try w.string(value)
        XCTAssertEqual(Int(w.bytes[0]), value.utf16.count + 1)
        var r = PTPReader(w.bytes)
        XCTAssertEqual(try r.string(), value)
    }

    func testStringLengthLimit() throws {
        var w = PTPWriter()
        try w.string(String(repeating: "x", count: 254))
        XCTAssertEqual(w.bytes[0], 255)
        XCTAssertThrowsError(try w.string(String(repeating: "x", count: 255)))
    }

    func testStringUnderflowThrows() {
        var r = PTPReader([5, 0x41, 0])
        XCTAssertThrowsError(try r.string())
    }

    // MARK: Integers and arrays

    func testIntegerWidthsRoundTrip() throws {
        var w = PTPWriter()
        w.u8(0xAB); w.i8(-2); w.u16(0xBEEF); w.i16(-3); w.u32(0xDEAD_BEEF); w.i32(-4)
        w.u64(0x0102_0304_0506_0708); w.i64(-5); w.raw(Array(0..<16))
        var r = PTPReader(w.bytes)
        XCTAssertEqual(try r.u8(), 0xAB)
        XCTAssertEqual(try r.i8(), -2)
        XCTAssertEqual(try r.u16(), 0xBEEF)
        XCTAssertEqual(try r.i16(), -3)
        XCTAssertEqual(try r.u32(), 0xDEAD_BEEF)
        XCTAssertEqual(try r.i32(), -4)
        XCTAssertEqual(try r.u64(), 0x0102_0304_0506_0708)
        XCTAssertEqual(try r.i64(), -5)
        XCTAssertEqual(try r.u128(), Array(0..<16))
        XCTAssertTrue(r.isAtEnd)
        XCTAssertThrowsError(try r.u8())
    }

    func testArraysRoundTripAndCorruptCountFails() throws {
        var w = PTPWriter()
        w.u16Array([1, 0x9805, 0xFFFF])
        w.u32Array([])
        var r = PTPReader(w.bytes)
        XCTAssertEqual(try r.u16Array(), [1, 0x9805, 0xFFFF])
        XCTAssertEqual(try r.u32Array(), [])
        var corrupt = PTPReader([0xFF, 0xFF, 0xFF, 0x7F, 1, 0])
        XCTAssertThrowsError(try corrupt.u32Array())
    }

    // MARK: Datasets

    func testDeviceInfoRoundTrip() throws {
        let info = PTPDeviceInfo(
            vendorExtensionDesc: "microsoft.com: 1.0; android.com: 1.0;",
            operationsSupported: [0x1001, 0x1002, 0x9805, 0x95C1], eventsSupported: [0x4002],
            devicePropertiesSupported: [0xD402], captureFormats: [], playbackFormats: [0x3000, 0x3001],
            manufacturer: "Xiaomi", model: "REDMI Note 15 5G", deviceVersion: "1.0", serialNumber: "10000001"
        )
        let decoded = try PTPDeviceInfo.decode(try info.encode())
        XCTAssertEqual(decoded, info)
        XCTAssertTrue(decoded.supports(PTPOperation.getObjectPropList))
        XCTAssertFalse(decoded.supports(PTPOperation.getPartialObject))
    }

    func testStorageInfoRoundTrip() throws {
        let info = PTPStorageInfo(storageType: 3, filesystemType: 2, accessCapability: 0,
                                  maxCapacity: 256_000_000_000, freeSpaceInBytes: 12_345_678_901,
                                  freeSpaceInObjects: 0xFFFF_FFFF, storageDescription: "Internal shared storage",
                                  volumeIdentifier: "")
        XCTAssertEqual(try PTPStorageInfo.decode(try info.encode()), info)
    }

    func testObjectInfoFieldOrderAndRoundTrip() throws {
        let info = PTPObjectInfo(storageID: 0x10001, objectFormat: 0x3801, protectionStatus: 0,
                                 compressedSize: 1234, parentObject: 77, associationType: 0,
                                 sequenceNumber: 0, filename: "IMG_1.jpg",
                                 captureDate: "", modificationDate: "20260929T101112", keywords: "")
        let encoded = try info.encode()
        // Filename starts after 52 bytes of fixed-width fields.
        XCTAssertEqual(encoded[52], UInt8("IMG_1.jpg".utf16.count + 1))
        XCTAssertEqual(Array(encoded[38..<42]), [77, 0, 0, 0]) // ParentObject
        XCTAssertEqual(try PTPObjectInfo.decode(encoded), info)
    }

    func testObjectInfoForUploadCapsSizeAndMarksFolders() {
        let big = PTPObjectInfo.forUpload(filename: "movie.mp4", size: 5_000_000_000)
        XCTAssertEqual(big.compressedSize, 0xFFFF_FFFF)
        let folder = PTPObjectInfo.forUpload(filename: "New", size: 0, format: PTPObjectFormat.association)
        XCTAssertEqual(folder.associationType, PTPAssociationType.genericFolder)
        XCTAssertTrue(folder.isFolder)
    }

    // MARK: ObjectPropList

    func testObjectPropListDecodesMixedTypes() throws {
        var w = PTPWriter()
        w.u32(7)
        func element(_ handle: UInt32, _ code: UInt16, _ type: UInt16, _ value: (inout PTPWriter) throws -> Void) rethrows {
            w.u32(handle); w.u16(code); w.u16(type); try value(&w)
        }
        try element(1, 0xDC07, 0xFFFF) { try $0.string("IMG_0001.jpg") }
        element(1, 0xDC02, 0x0004) { $0.u16(0x3801) }
        element(1, 0xDC04, 0x0008) { $0.u64(5_000_000_000) }
        try element(1, 0xDC09, 0xFFFF) { try $0.string("20260101T000000") }
        element(2, 0xDC09, 0x0000) { _ in } // UNDEF: no payload
        element(2, 0xDC41, 0x000A) { $0.raw(Array(repeating: 0xAB, count: 16)) }
        element(2, 0xDC99, 0x4002) { $0.u32(3); $0.raw([1, 2, 3]) } // array of uint8
        let elements = try MTPObjectPropList.decode(w.bytes)
        XCTAssertEqual(elements.count, 7)
        XCTAssertEqual(elements[0].value.stringValue, "IMG_0001.jpg")
        XCTAssertEqual(elements[1].value.unsignedValue, 0x3801)
        XCTAssertEqual(elements[2].value.unsignedValue, 5_000_000_000)
        XCTAssertEqual(elements[3].value, .string("20260101T000000"))
        XCTAssertEqual(elements[4].value, .undefined)
        XCTAssertNil(elements[4].value.stringValue)
        XCTAssertEqual(elements[5].value, .uint128(Array(repeating: 0xAB, count: 16)))
        XCTAssertEqual(elements[6].value, .array(elementType: 0x0002, count: 3, bytes: [1, 2, 3]))
        XCTAssertEqual(try MTPObjectPropList.decode(try MTPObjectPropList.encode(elements)), elements)
    }

    func testObjectPropListEmpty() throws {
        XCTAssertEqual(try MTPObjectPropList.decode([0, 0, 0, 0]), [])
    }

    func testObjectPropListTruncatedElementNamesIndex() {
        var w = PTPWriter()
        w.u32(2)
        w.u32(1); w.u16(0xDC04); w.u16(0x0006); w.u32(10)
        w.u32(2); w.u16(0xDC04); w.u16(0x0008); w.u16(1) // u64 value cut short
        XCTAssertThrowsError(try MTPObjectPropList.decode(w.bytes)) { error in
            XCTAssertTrue((error as? PTPDecodingError)?.message.contains("element 1") == true, "\(error)")
        }
    }

    func testObjectPropListUnknownDatatypeFails() {
        var w = PTPWriter()
        w.u32(1); w.u32(1); w.u16(0xDC04); w.u16(0x0077); w.u32(0)
        XCTAssertThrowsError(try MTPObjectPropList.decode(w.bytes))
    }

    func testObjectPropListCorruptCountFailsWithoutHugeAllocation() {
        XCTAssertThrowsError(try MTPObjectPropList.decode([0xFF, 0xFF, 0xFF, 0xFF, 0, 0]))
    }

    // MARK: Dates and status

    func testDateTimeVariants() throws {
        let utc = try XCTUnwrap(PTPDateTime.parse("20260929T101112"))
        XCTAssertEqual(PTPDateTime.format(utc), "20260929T101112")
        XCTAssertEqual(PTPDateTime.parse("20260929T101112Z"), utc)
        XCTAssertEqual(PTPDateTime.parse("20260929T101112.0"), utc)
        XCTAssertEqual(PTPDateTime.parse("20260929T101112..."), utc) // Samsung
        XCTAssertEqual(PTPDateTime.parse("20260929T121112+0200"), utc) // Lumia
        XCTAssertNil(PTPDateTime.parse(""))
        XCTAssertNil(PTPDateTime.parse("garbage"))
        XCTAssertNil(PTPDateTime.parse("20261332T000000"))
    }

    func testDeviceStatusDecode() throws {
        let status = try PTPDeviceStatus.decode([8, 0, 0x19, 0x20, 0x81, 0, 0, 0])
        XCTAssertEqual(status.code, PTPResponseCode.deviceBusy)
        XCTAssertEqual(status.parameters, [0x81])
    }

    // MARK: Interface selection

    private func candidate(_ name: String?, cls: Int, sub: Int = 0, proto: Int = 0, endpoints: Int = 3, id: UInt64 = 1) -> MTPInterfaceCandidate {
        MTPInterfaceCandidate(registryEntryID: id, vendorID: 0x2717, productID: 0xFF48, manufacturer: "Xiaomi",
                              productName: "Phone", serialNumber: "1", locationID: nil, interfaceNumber: 0,
                              interfaceClass: cls, interfaceSubClass: sub, interfaceProtocol: proto,
                              interfaceName: name, endpointCount: endpoints)
    }

    func testInterfaceSelectionRules() {
        XCTAssertTrue(MTPInterfaceSelection.qualifies(candidate("MTP", cls: 6, sub: 1, proto: 1)))
        XCTAssertTrue(MTPInterfaceSelection.qualifies(candidate("MTP", cls: 0xFF, sub: 0xFF)))
        XCTAssertFalse(MTPInterfaceSelection.qualifies(candidate("PTP", cls: 6, sub: 1, proto: 1)), "iPhone")
        XCTAssertFalse(MTPInterfaceSelection.qualifies(candidate("ADB Interface", cls: 0xFF, sub: 0x42, proto: 1, endpoints: 2)))
        XCTAssertFalse(MTPInterfaceSelection.qualifies(candidate("MTP", cls: 6, endpoints: 2)))
        let unnamed = candidate(nil, cls: 6, sub: 1, proto: 1)
        XCTAssertTrue(MTPInterfaceSelection.qualifies(unnamed))
        XCTAssertTrue(unnamed.needsVendorExtensionCheck)
        XCTAssertTrue(MTPInterfaceSelection.vendorExtensionAcceptable("microsoft.com: 1.0; android.com: 1.0;"))
        XCTAssertFalse(MTPInterfaceSelection.vendorExtensionAcceptable(""))
        let ordered = MTPInterfaceSelection.select([unnamed, candidate("MTP", cls: 6, id: 9), candidate("PTP", cls: 6, id: 3)])
        XCTAssertEqual(ordered.map(\.registryEntryID), [9, 1])
    }
}
