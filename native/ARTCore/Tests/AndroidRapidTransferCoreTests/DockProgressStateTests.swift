import Foundation
import XCTest
@testable import AndroidRapidTransferCore

final class DockProgressStateTests: XCTestCase {
    func testNilProgressIsHidden() {
        XCTAssertEqual(DockProgressState(nil), .hidden)
    }

    func testProgressWithNoKnownFilesIsIndeterminate() throws {
        let progress = try XCTUnwrap(Self.overallProgress(filesCompleted: 0, totalFiles: 0))

        XCTAssertEqual(DockProgressState(progress), .indeterminate)
    }

    func testMidTransferProgressIsDeterminate() throws {
        let progress = try XCTUnwrap(Self.overallProgress(filesCompleted: 2, totalFiles: 4))

        XCTAssertEqual(DockProgressState(progress), .determinate(0.5))
    }

    func testDeterminateProgressIsClampedAtBothEnds() throws {
        let belowZero = try XCTUnwrap(
            Self.overallProgress(filesCompleted: -1, totalFiles: 4)
        )
        let aboveOne = try XCTUnwrap(
            Self.overallProgress(filesCompleted: 5, totalFiles: 4)
        )

        XCTAssertEqual(DockProgressState(belowZero), .determinate(0))
        XCTAssertEqual(DockProgressState(aboveOne), .determinate(1))
    }

    private static func overallProgress(
        filesCompleted: Int64,
        totalFiles: Int64
    ) -> TransferOverallProgress? {
        let progress = TransferProgressSnapshot(
            percent: 0,
            speed: 0,
            currentFileName: "photo.jpg",
            filesSent: filesCompleted,
            totalFiles: totalFiles,
            totalBytes: 0,
            sentBytes: 0
        )
        let request = TransferRequest(
            direction: .download,
            sources: ["/DCIM/photo.jpg"],
            destination: "/tmp",
            storageId: 1
        )
        let row = TransferPanelRow(
            job: TransferJobSnapshot(
                id: UUID(),
                request: request,
                state: .transferring(progress)
            )
        )
        return TransferOverallProgress(rows: [row])
    }
}
