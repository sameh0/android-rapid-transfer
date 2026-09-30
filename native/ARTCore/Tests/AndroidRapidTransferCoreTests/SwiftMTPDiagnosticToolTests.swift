import Foundation
import SwiftMTP
import XCTest
@testable import AndroidRapidTransferCore

final class SwiftMTPDiagnosticToolTests: XCTestCase {
    func testCompletedDiagnosticIsASuccess() async {
        let tool = SwiftMTPDiagnosticTool { _ in
            SwiftMTPDiagnosticReport(text: "Model: Fake\nDIAGNOSTIC complete\n", completed: true)
        }

        let result = await tool.run()

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.reportText.contains("Outcome: completed"), result.reportText)
        XCTAssertTrue(result.reportText.contains("Model: Fake"))
    }

    func testIncompleteDiagnosticKeepsItsReport() async {
        let tool = SwiftMTPDiagnosticTool { _ in
            SwiftMTPDiagnosticReport(text: "ERROR: open: busy\n", completed: false)
        }

        let result = await tool.run()

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.reportText.contains("did not complete"), result.reportText)
        XCTAssertTrue(result.reportText.contains("ERROR: open: busy"))
    }

    func testOverrunningDiagnosticIsCancelledAndReportsWhatItHas() async {
        let tool = SwiftMTPDiagnosticTool(timeout: .milliseconds(100), cancellationGrace: .seconds(5)) { cancellation in
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            return SwiftMTPDiagnosticReport(text: "partial: stopped after cancel\n", completed: false)
        }

        let result = await tool.run()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result, DebugToolResult(
            name: SwiftMTPDiagnosticTool.name,
            report: "partial: stopped after cancel\n",
            termination: .timedOut(seconds: 0)
        ))
        XCTAssertTrue(result.reportText.contains("timed out"), result.reportText)
    }

    func testDiagnosticThatIgnoresCancellationStillReturns() async {
        let release = DispatchSemaphore(value: 0)
        let tool = SwiftMTPDiagnosticTool(timeout: .milliseconds(50), cancellationGrace: .milliseconds(50)) { _ in
            release.wait()
            return SwiftMTPDiagnosticReport(text: "late", completed: true)
        }

        let result = await tool.run()
        release.signal()

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.reportText.contains("no output"), result.reportText)
    }

    func testTheBugReportListsTheDiagnostic() {
        XCTAssertEqual(SwiftMTPDiagnosticTool().reportItem, .deviceDiagnostic)
        XCTAssertTrue(BugReportGenerator.contents().contains(.deviceDiagnostic))
    }
}
