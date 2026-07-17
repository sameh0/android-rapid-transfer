import Foundation
import XCTest
@testable import SwiftMTP

final class MTPSessionTests: XCTestCase {
    private func openedSession(_ transport: FakeTransport, chunk: Int = 1 << 20) throws -> MTPSession {
        let session = MTPSession(transport: transport, timeout: 1, transferChunkSize: chunk)
        transport.deviceResponds(tid: 0)
        try session.openSession(id: 1)
        return session
    }

    // MARK: Session management and transaction IDs

    func testGetDeviceInfoOutsideSessionUsesTransactionZero() throws {
        let transport = FakeTransport()
        let session = MTPSession(transport: transport)
        let info = PTPDeviceInfo(operationsSupported: [0x1001, 0x9805], manufacturer: "Xiaomi", model: "Note")
        transport.deviceSendsData(code: 0x1001, tid: 0, payload: try info.encode())
        transport.deviceResponds(tid: 0)
        XCTAssertEqual(try session.getDeviceInfo(), info)
        XCTAssertEqual(transport.writes.first.map { [UInt8]($0) }, PTPCommand(code: 0x1001, transactionID: 0).bytes)
        XCTAssertEqual(transport.remainingPackets, 0)
    }

    func testOpenSessionThenTransactionIDsCountFromOne() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        XCTAssertEqual(transport.commands.last, PTPCommand(code: 0x1002, transactionID: 0, parameters: [1]))
        XCTAssertEqual(session.sessionID, 1)
        for tid in UInt32(1)...3 {
            transport.deviceResponds(tid: tid, params: [tid * 10])
            XCTAssertEqual(try session.getNumObjects(storageID: 0x10001, parent: PTPHandle.root), tid * 10)
        }
        XCTAssertEqual(transport.commands.map(\.transactionID), [0, 1, 2, 3])
        XCTAssertEqual(transport.commands[1].parameters, [0x10001, 0, 0xFFFF_FFFF])
    }

    func testSessionAlreadyOpenClosesAndReopens() throws {
        let transport = FakeTransport()
        let session = MTPSession(transport: transport, timeout: 1)
        transport.deviceResponds(PTPResponseCode.sessionAlreadyOpen, tid: 0)
        transport.deviceResponds(tid: 0) // CloseSession
        transport.deviceResponds(tid: 0) // OpenSession again
        try session.openSession(id: 1)
        XCTAssertEqual(transport.commands.map(\.code), [0x1002, 0x1003, 0x1002])
        XCTAssertTrue(session.isSessionOpen)
    }

    func testOpenSessionFailureThrowsTypedError() {
        let transport = FakeTransport()
        let session = MTPSession(transport: transport, timeout: 1)
        transport.deviceResponds(PTPResponseCode.deviceBusy, tid: 0)
        XCTAssertThrowsError(try session.openSession()) { error in
            XCTAssertEqual(error as? MTPResponseError, MTPResponseError(operation: 0x1002, code: 0x2019))
        }
        XCTAssertFalse(session.isSessionOpen)
    }

    func testCloseSendsCloseSessionAndReleasesOnce() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceResponds(tid: 1)
        session.close()
        session.close()
        XCTAssertEqual(transport.commands.last?.code, 0x1003)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertThrowsError(try session.getStorageIDs())
    }

    // MARK: Data-in phases

    func testMultiPacketDataPhaseAcrossManyReads() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport, chunk: 1024)
        let payload = patterned(5000)
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: payload)
        transport.deviceResponds(tid: 1)
        var received = Data()
        var progress: [UInt64] = []
        try session.getObject(7, sink: { received.append($0) }, progress: { done, total in
            XCTAssertEqual(total, 5000)
            progress.append(done)
        })
        XCTAssertEqual([UInt8](received), payload)
        XCTAssertEqual(progress.last, 5000)
        XCTAssertGreaterThan(progress.count, 3)
        // Reads never ask for more than the container still holds (rounded to packets).
        XCTAssertTrue(transport.readRequests.allSatisfy { $0 % 512 == 0 && $0 <= 1024 })
        XCTAssertEqual(transport.remainingPackets, 0)
    }

    func testDataPhaseExactMultipleOfPacketSizeWithZLP() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport)
        let payload = patterned(1024 - 12)
        transport.deviceSendsData(code: 0x1004, tid: 1, payload: payload, zlp: true)
        transport.deviceResponds(tid: 1)
        let (_, bytes) = try session.executeData(0x1004)
        XCTAssertEqual(bytes, payload)
        XCTAssertEqual(transport.remainingPackets, 0)
    }

    func testDataPhaseExactMultipleWithoutZLPGluesResponse() throws {
        // Some stacks (Linux XHCI among them) omit the ZLP, so the
        // response lands in the same transfer as the data.
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport)
        let payload = patterned(512 - 12)
        transport.deviceSendsData(code: 0x1004, tid: 1, payload: payload, zlp: false)
        transport.deviceResponds(tid: 1, params: [5])
        let (response, bytes) = try session.executeData(0x1004)
        XCTAssertEqual(bytes, payload)
        XCTAssertEqual(response.parameters, [5])
        XCTAssertEqual(transport.remainingPackets, 0)
    }

    func testRemainingExactMultipleLeavesZLPForResponseRead() throws {
        // Second read asks for exactly the remaining 512 bytes; the ZLP that
        // follows is skipped when the response is read.
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport, chunk: 512)
        let payload = patterned(1024 - 12)
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: payload, zlp: true)
        transport.deviceResponds(tid: 1)
        var received = Data()
        try session.getObject(1, sink: { received.append($0) })
        XCTAssertEqual([UInt8](received), payload)
        XCTAssertEqual(transport.remainingPackets, 0)
    }

    func testShortPacketsMidPhaseKeepReadingToDeclaredLength() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport)
        let payload = patterned(700)
        let container = PTPContainerHeader(length: 712, type: .data, code: 0x1009, transactionID: 1).bytes + payload
        // Device ends several transfers early with short packets.
        transport.deviceSends(Array(container[0..<100]))
        transport.deviceSends(Array(container[100..<300]))
        transport.deviceSends(Array(container[300...]))
        transport.deviceResponds(tid: 1)
        var received = Data()
        try session.getObject(1, sink: { received.append($0) })
        XCTAssertEqual([UInt8](received), payload)
        XCTAssertFalse(session.separateHeader)
    }

    func testSeparateHeaderPacketIsDetected() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport)
        let payload = patterned(600)
        transport.deviceSends(PTPContainerHeader(length: 612, type: .data, code: 0x1009, transactionID: 1).bytes)
        transport.deviceSends(payload)
        transport.deviceResponds(tid: 1)
        var received = Data()
        try session.getObject(1, sink: { received.append($0) })
        XCTAssertEqual([UInt8](received), payload)
        XCTAssertTrue(session.separateHeader)
    }

    func testUnknownLengthMarkerReadsUntilShortPacket() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport, chunk: 1024)
        let payload = patterned(3000)
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: payload, lengthField: 0xFFFF_FFFF)
        transport.deviceResponds(tid: 1)
        var received = Data()
        var totals: [UInt64?] = []
        try session.getObject(1, sink: { received.append($0) }, progress: { _, total in totals.append(total) })
        XCTAssertEqual([UInt8](received), payload)
        XCTAssertTrue(totals.allSatisfy { $0 == nil })
        XCTAssertEqual(transport.remainingPackets, 0)
    }

    func testUnknownLengthEndingOnPacketBoundaryUsesZLP() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport, chunk: 1024)
        let payload = patterned(2048 - 12)
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: payload, zlp: true, lengthField: 0xFFFF_FFFF)
        transport.deviceResponds(tid: 1)
        var received = Data()
        try session.getObject(1, sink: { received.append($0) })
        XCTAssertEqual([UInt8](received), payload)
        XCTAssertEqual(transport.remainingPackets, 0)
    }

    func testUnexpectedDataPhaseIsProtocolError() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceSendsData(code: 0x1006, tid: 1, payload: [1, 2, 3, 4])
        transport.deviceResponds(tid: 1, params: [1])
        XCTAssertThrowsError(try session.getNumObjects(storageID: 1, parent: 0)) { error in
            XCTAssertTrue(error is MTPProtocolError, "\(error)")
        }
        XCTAssertEqual(transport.remainingPackets, 0, "the transaction is still drained")
    }

    func testTransactionIDMismatchIsProtocolError() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceResponds(tid: 99, params: [0])
        XCTAssertThrowsError(try session.getNumObjects(storageID: 1, parent: 0)) { error in
            XCTAssertTrue(error is MTPProtocolError)
        }
    }

    func testNonOKResponseAfterNoDataPhase() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceResponds(PTPResponseCode.mtpInvalidObjectPropCode, tid: 1)
        XCTAssertThrowsError(try session.getObjectPropList(handle: 5, property: MTPObjectProperty.all)) { error in
            let responseError = error as? MTPResponseError
            XCTAssertEqual(responseError?.code, 0xA801)
            XCTAssertEqual(responseError?.operation, 0x9805)
            XCTAssertTrue(responseError?.description.contains("MTP_InvalidObjectPropCode") == true)
        }
        XCTAssertEqual(transport.commands.last?.parameters, [5, 0, 0xFFFF_FFFF, 0, 1])
        // transact() hands the non-OK response back instead of throwing.
        transport.deviceResponds(PTPResponseCode.invalidObjectHandle, tid: 2)
        let response = try session.transact(PTPOperation.getObjectInfo, [123], dataIn: { _ in })
        XCTAssertEqual(response.code, PTPResponseCode.invalidObjectHandle)
    }

    func testNonOKResponseAfterDataPhase() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: [1, 2, 3])
        transport.deviceResponds(PTPResponseCode.incompleteTransfer, tid: 1)
        XCTAssertThrowsError(try session.getObject(1, sink: { _ in })) { error in
            XCTAssertEqual((error as? MTPResponseError)?.code, PTPResponseCode.incompleteTransfer)
        }
    }

    func testStallClearsBothBulkPipes() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.stallNextRead = true
        XCTAssertThrowsError(try session.getStorageIDs()) { error in
            XCTAssertEqual((error as? MTPTransportError)?.kind, .stall)
        }
        XCTAssertEqual(transport.clearedStalls, [.bulkIn, .bulkOut])
    }

    // MARK: Operations and parameters

    func testGetObjectPropListDecodesReply() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        let elements = [
            MTPObjectPropListElement(handle: 10, propertyCode: 0xDC07, value: .string("a.jpg")),
            MTPObjectPropListElement(handle: 11, propertyCode: 0xDC07, value: .string("b.jpg"))
        ]
        transport.deviceSendsData(code: 0x9805, tid: 1, payload: try MTPObjectPropList.encode(elements))
        transport.deviceResponds(tid: 1)
        XCTAssertEqual(try session.getObjectPropList(handle: 3, property: UInt32(MTPObjectProperty.objectFileName)), elements)
        XCTAssertEqual(transport.commands.last?.parameters, [3, 0, 0xDC07, 0, 1])
    }

    func testGetPartialObject64SplitsOffset() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceSendsData(code: 0x95C1, tid: 1, payload: [9, 8, 7])
        transport.deviceResponds(tid: 1)
        let data = try session.getPartialObject64(4, offset: 0x1_2345_6789, maxBytes: 3)
        XCTAssertEqual([UInt8](data), [9, 8, 7])
        XCTAssertEqual(transport.commands.last, PTPCommand(code: 0x95C1, transactionID: 1, parameters: [4, 0x2345_6789, 1, 3]))
    }

    func testGetPartialObjectParameters() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceSendsData(code: 0x101B, tid: 1, payload: [1])
        transport.deviceResponds(tid: 1, params: [1])
        XCTAssertEqual(try session.getPartialObject(4, offset: 100, maxBytes: 1), Data([1]))
        XCTAssertEqual(transport.commands.last?.parameters, [4, 100, 1])
    }

    func testSendObjectInfoEncodesDatasetAndReturnsAssignedHandle() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceResponds(tid: 1, params: [0x10001, 5, 0x77])
        let info = PTPObjectInfo.forUpload(filename: "x.txt", size: 3)
        let result = try session.sendObjectInfo(storageID: 0x10001, parent: 5, info: info)
        XCTAssertEqual(result.handle, 0x77)
        let dataWrite = [UInt8](transport.writes[2])
        let header = try PTPContainerHeader.decode(Array(dataWrite[0..<12]))
        XCTAssertEqual(header.containerType, .data)
        XCTAssertEqual(header.code, 0x100C)
        XCTAssertEqual(header.transactionID, 1)
        XCTAssertEqual(Int(header.length), dataWrite.count)
        XCTAssertEqual(try PTPObjectInfo.decode(Array(dataWrite[12...])), info)
    }

    func testSetObjectPropValueSendsEncodedString() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.deviceResponds(tid: 1)
        try session.setObjectPropValue(9, property: MTPObjectProperty.objectFileName, value: .string("new.jpg"))
        var expected = PTPWriter()
        try expected.string("new.jpg")
        XCTAssertEqual([UInt8](transport.writes[2].dropFirst(12)), expected.bytes)
        XCTAssertEqual(transport.commands.last?.parameters, [9, 0xDC07])
    }

    // MARK: Data-out phases

    func testSendObjectStreamsWholePacketsThenShortTail() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport, chunk: 1024)
        let payload = patterned(3000)
        transport.deviceResponds(tid: 1)
        var progress: [UInt64] = []
        try session.sendObject(MTPDataSource(bytes: payload), progress: { done, _ in progress.append(done) })
        let dataWrites = Array(transport.writes.dropFirst(2)) // OpenSession cmd, SendObject cmd
        XCTAssertEqual(dataWrites.dropLast().map(\.count), Array(repeating: 1024, count: dataWrites.count - 1))
        let wire = dataWrites.reduce(Data(), +)
        let header = try PTPContainerHeader.decode(Array(wire.prefix(12)))
        XCTAssertEqual(header.length, 3012)
        XCTAssertEqual(header.code, 0x100D)
        XCTAssertEqual([UInt8](wire.dropFirst(12)), payload)
        XCTAssertNotEqual(dataWrites.last?.count, 0, "3012 is not a packet multiple: no ZLP")
        XCTAssertEqual(progress.last, 3000)
    }

    func testSendObjectExactPacketMultipleEndsWithZLP() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport, chunk: 1024)
        transport.deviceResponds(tid: 1)
        try session.sendObject(MTPDataSource(bytes: patterned(2048 - 12)))
        XCTAssertEqual(transport.writes.last?.count, 0, "container of 2048 bytes needs a ZLP")
        XCTAssertEqual(transport.writes.dropLast().last?.count, 1024)
    }

    func testSendObjectEmptyPayloadIsHeaderOnly() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport)
        transport.deviceResponds(tid: 1)
        try session.sendObject(MTPDataSource(bytes: []))
        XCTAssertEqual(transport.writes.last?.count, 12)
    }

    func testSendDataOver4GBUsesUnknownLengthMarker() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport, chunk: 1024)
        struct Stop: Error {}
        var calls = 0
        let source = MTPDataSource(length: 5_000_000_000) { maxLength in
            calls += 1
            if calls > 1 { throw Stop() }
            return Data(count: maxLength)
        }
        XCTAssertThrowsError(try session.sendObject(source)) { XCTAssertTrue($0 is Stop) }
        let firstData = [UInt8](transport.writes[2])
        XCTAssertEqual(try PTPContainerHeader.decode(Array(firstData[0..<12])).length, 0xFFFF_FFFF)
        XCTAssertEqual(firstData.count, 1024)
    }

    func testShortDataSourceAbortsTheTransactionAndKeepsTheSession() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        let source = MTPDataSource(length: 10) { _ in Data() }
        XCTAssertThrowsError(try session.sendObject(source)) { XCTAssertTrue($0 is MTPDataSourceError, "\($0)") }
        XCTAssertEqual(transport.cancelledTransactions, [1])
        XCTAssertFalse(session.isBroken)
        transport.deviceResponds(tid: 2, params: [3])
        XCTAssertEqual(try session.getNumObjects(storageID: 1, parent: 0), 3)
    }

    // MARK: Abort and recovery

    private struct SinkFailure: Error {}

    func testSinkFailureCancelsDrainsAndKeepsTheSession() throws {
        let transport = FakeTransport(maxPacketSize: 512)
        let session = try openedSession(transport, chunk: 1024)
        session.abortDrainTimeout = 0.01
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: patterned(10_000))
        transport.deviceResponds(PTPResponseCode.transactionCancelled, tid: 1)
        transport.deviceStatusReplies = [Data([4, 0, 0x19, 0x20])] // DeviceBusy once
        XCTAssertThrowsError(try session.getObject(9, sink: { _ in throw SinkFailure() })) {
            XCTAssertTrue($0 is SinkFailure)
        }
        XCTAssertEqual(transport.cancelledTransactions, [1])
        XCTAssertGreaterThanOrEqual(transport.deviceStatusRequests, 2, "polled until OK")
        XCTAssertEqual(transport.remainingPackets, 0, "stale data and response drained")
        XCTAssertFalse(session.isBroken)
        transport.deviceResponds(tid: 2, params: [4])
        XCTAssertEqual(try session.getNumObjects(storageID: 1, parent: 0), 4)
    }

    func testLateResponseOfAnAbandonedTransactionIsSkipped() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        session.abortDrainTimeout = 0.01
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: [1, 2, 3])
        XCTAssertThrowsError(try session.getObject(9, sink: { _ in throw SinkFailure() }))
        // The device only answers the cancelled transaction after the drain.
        transport.deviceResponds(PTPResponseCode.transactionCancelled, tid: 1)
        transport.deviceResponds(tid: 2, params: [7])
        XCTAssertEqual(try session.getNumObjects(storageID: 1, parent: 0), 7)
        // Also when the late container arrives where a data phase was expected.
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: patterned(700))
        transport.deviceSendsData(code: 0x1004, tid: 3, payload: [1, 0, 0, 0, 1, 0, 1, 0])
        transport.deviceResponds(tid: 3)
        XCTAssertEqual(try session.getStorageIDs(), [0x10001])
        XCTAssertFalse(session.isBroken)
    }

    func testAbortThatNeverSettlesBreaksTheSession() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        session.abortDrainTimeout = 0.01
        session.abortStatusTimeout = 0.05
        transport.deviceStatus = Data([4, 0, 0x19, 0x20]) // DeviceBusy forever
        transport.deviceSendsData(code: 0x1009, tid: 1, payload: [1, 2, 3])
        XCTAssertThrowsError(try session.getObject(9, sink: { _ in throw SinkFailure() }))
        XCTAssertTrue(session.isBroken)
        let writes = transport.writes.count
        XCTAssertThrowsError(try session.getStorageIDs()) {
            XCTAssertEqual(($0 as? MTPTransportError)?.kind, .noDevice)
        }
        XCTAssertEqual(transport.writes.count, writes, "a broken session sends nothing")
    }

    func testUSBErrorBreaksTheSession() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        transport.failNextRead = MTPTransportError(.noDevice, status: IOReturnCode.noDevice, "gone")
        XCTAssertThrowsError(try session.getStorageIDs())
        XCTAssertTrue(session.isBroken)
        XCTAssertEqual(transport.cancelledTransactions, [], "no cancel is sent to a vanished device")
        XCTAssertThrowsError(try session.getStorageIDs()) {
            XCTAssertEqual(($0 as? MTPTransportError)?.kind, .noDevice)
        }
    }

    func testStallRecoversWithoutBreakingTheSession() throws {
        let transport = FakeTransport()
        let session = try openedSession(transport)
        session.abortDrainTimeout = 0.01
        transport.stallNextRead = true
        XCTAssertThrowsError(try session.getStorageIDs())
        XCTAssertFalse(session.isBroken)
        XCTAssertEqual(transport.cancelledTransactions, [], "a stall is not cancelled, only cleared")
        transport.deviceResponds(tid: 2, params: [1])
        XCTAssertEqual(try session.getNumObjects(storageID: 1, parent: 0), 1)
    }

    // MARK: Class requests

    func testCancelAndDeviceStatusGoThroughTransport() throws {
        let transport = FakeTransport()
        let session = MTPSession(transport: transport)
        try session.cancelTransaction(12)
        XCTAssertEqual(transport.cancelledTransactions, [12])
        XCTAssertEqual(try session.deviceStatus().code, PTPResponseCode.ok)
    }
}
