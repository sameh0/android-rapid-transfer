@testable import AndroidRapidTransferCore
import MTPKit
import XCTest

@MainActor
final class TransferCompletionNotifierTests: XCTestCase {
    func testNothingIsPostedWhileTheAppIsFrontmost() async {
        let center = FakeNotificationCenter(authorization: .authorized)
        let notifier = TransferCompletionNotifier(center: center, isAppActive: { true })

        let posted = await notifier.sessionFinished(Self.summary(.completed))
        XCTAssertFalse(posted)
        let requests = await center.authorizationRequests
        let notifications = await center.posted
        XCTAssertEqual(requests, 0, "No permission prompt while the user is looking at the app")
        XCTAssertTrue(notifications.isEmpty)
    }

    func testPermissionIsAskedLazilyAtTheFirstBackgroundFinish() async {
        let center = FakeNotificationCenter(authorization: .notDetermined, grants: true)
        let notifier = TransferCompletionNotifier(center: center, isAppActive: { false })
        var requests = await center.authorizationRequests
        XCTAssertEqual(requests, 0, "Creating the notifier never prompts")

        let summary = Self.summary(.completed)
        let posted = await notifier.sessionFinished(summary)
        XCTAssertTrue(posted)
        requests = await center.authorizationRequests
        let notifications = await center.posted
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(notifications, [TransferCompletionNotification(summary: summary)])

        // Allowed once, it posts without asking again.
        _ = await notifier.sessionFinished(Self.summary(.completed))
        requests = await center.authorizationRequests
        XCTAssertEqual(requests, 1)
    }

    func testARefusalIsRespected() async {
        let center = FakeNotificationCenter(authorization: .notDetermined, grants: false)
        let notifier = TransferCompletionNotifier(center: center, isAppActive: { false })
        let first = await notifier.sessionFinished(Self.summary(.completed))
        XCTAssertFalse(first)

        let second = await notifier.sessionFinished(Self.summary(.completed))
        XCTAssertFalse(second)
        let requests = await center.authorizationRequests
        let notifications = await center.posted
        XCTAssertEqual(requests, 1, "A denial is never re-prompted")
        XCTAssertTrue(notifications.isEmpty)
    }

    func testAStoppedSessionPostsNothing() async {
        let center = FakeNotificationCenter(authorization: .authorized)
        let notifier = TransferCompletionNotifier(center: center, isAppActive: { false })
        let posted = await notifier.sessionFinished(Self.summary(.cancelled, sent: 0))
        XCTAssertFalse(posted)
    }

    func testWithoutANotificationCenterItStaysSilent() async {
        let notifier = TransferCompletionNotifier(center: nil, isAppActive: { false })
        let posted = await notifier.sessionFinished(Self.summary(.completed))
        XCTAssertFalse(posted)
    }

    func testNotificationTextReadsLikeThePanel() async {
        let clean = TransferCompletionNotification(summary: Self.summary(.completed, bytes: 2_000_000))
        XCTAssertEqual(clean.title, "All 12 files copied")
        XCTAssertTrue(clean.body.hasSuffix("copied to this Mac"), clean.body)

        let failed = TransferCompletionNotification(summary: Self.summary(.failed(errorType: .unknown, message: "x")))
        XCTAssertTrue(failed.body.contains("needs attention"), failed.body)
        XCTAssertNotEqual(clean.identifier, failed.identifier)
    }

    private static func summary(
        _ state: TransferJobState,
        sent: Int64 = 12,
        bytes: Int64 = 1_000
    ) -> TransferSessionSummary {
        let row = TransferPanelRow(job: TransferJobSnapshot(
            id: UUID(),
            request: TransferRequest(direction: .download, sources: ["/DCIM"], destination: "/tmp", storageId: 1),
            state: state,
            lastProgress: TransferProgressSnapshot(
                percent: 100,
                speed: 1,
                currentFileName: "a.jpg",
                filesSent: sent,
                totalFiles: 12,
                totalBytes: bytes,
                sentBytes: bytes
            )
        ))
        // A terminal row always summarizes.
        return TransferSessionSummary(rows: [row])!
    }
}

private actor FakeNotificationCenter: UserNotificationPosting {
    private var status: UserNotificationAuthorization
    private let grants: Bool
    private(set) var authorizationRequests = 0
    private(set) var posted: [TransferCompletionNotification] = []

    init(authorization: UserNotificationAuthorization, grants: Bool = true) {
        status = authorization
        self.grants = grants
    }

    func authorization() -> UserNotificationAuthorization { status }

    func requestAuthorization() -> Bool {
        authorizationRequests += 1
        status = grants ? .authorized : .denied
        return grants
    }

    func post(_ notification: TransferCompletionNotification) {
        posted.append(notification)
    }
}
