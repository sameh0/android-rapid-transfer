import XCTest
@testable import AndroidRapidTransfer

final class DeviceDragPayloadTests: XCTestCase {
    func testRejectsPayloadFromStaleTransferSession() {
        let activeSessionID = UUID()
        let stalePayload = DeviceDragPayload(
            sources: ["/DCIM/old-session.jpg"],
            storageID: 1,
            sessionID: UUID()
        )

        XCTAssertNil(
            DeviceDragPayload.acceptedItems(
                from: [stalePayload],
                activeSessionID: activeSessionID
            )
        )
    }

    func testAcceptsPayloadFromActiveTransferSession() throws {
        let activeSessionID = UUID()
        let payload = DeviceDragPayload(
            sources: ["/DCIM/current-session.jpg"],
            storageID: 7,
            sessionID: activeSessionID
        )

        let accepted = try XCTUnwrap(
            DeviceDragPayload.acceptedItems(
                from: [payload],
                activeSessionID: activeSessionID
            )
        )
        XCTAssertEqual(accepted.sources, payload.sources)
        XCTAssertEqual(accepted.storageID, payload.storageID)
    }
}
