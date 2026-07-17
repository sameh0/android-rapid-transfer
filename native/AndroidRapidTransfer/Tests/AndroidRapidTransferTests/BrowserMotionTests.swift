@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import XCTest

final class BrowserMotionTests: XCTestCase {
    func testNavigationDirectionFollowsThePathHierarchy() {
        XCTAssertEqual(BrowserNavigationDirection.resolve(from: "/", to: "/DCIM"), .forward)
        XCTAssertEqual(BrowserNavigationDirection.resolve(from: "/DCIM", to: "/DCIM/Camera/2026"), .forward)
        XCTAssertEqual(BrowserNavigationDirection.resolve(from: "/DCIM/Camera", to: "/DCIM"), .backward)
        XCTAssertEqual(BrowserNavigationDirection.resolve(from: "/DCIM/Camera", to: "/"), .backward)
        XCTAssertEqual(BrowserNavigationDirection.resolve(from: "/DCIM", to: "/Download"), .lateral)
        XCTAssertEqual(BrowserNavigationDirection.resolve(from: "/DCIM", to: "/DCIM"), .lateral)
    }

    func testSiblingSharingANamePrefixIsNotADescendant() {
        XCTAssertEqual(BrowserNavigationDirection.resolve(from: "/Music", to: "/MusicVideos"), .lateral)
        XCTAssertEqual(BrowserNavigationDirection.resolve(from: "/MusicVideos", to: "/Music"), .lateral)
    }

    func testEntryOffsetComesFromTheSideOfTravel() {
        XCTAssertGreaterThan(BrowserNavigationDirection.forward.entryOffset, 0)
        XCTAssertLessThan(BrowserNavigationDirection.backward.entryOffset, 0)
        XCTAssertEqual(BrowserNavigationDirection.lateral.entryOffset, 0)
    }

    func testListingChangesAnimateOnlyWithinAFolderAndForSmallListings() {
        XCTAssertTrue(BrowserListingAnimation.animatesChanges(
            displayedLocation: "/A", location: "/A", itemCount: 12, reduceMotion: false
        ))
        XCTAssertFalse(BrowserListingAnimation.animatesChanges(
            displayedLocation: "/A", location: "/B", itemCount: 12, reduceMotion: false
        ))
        XCTAssertFalse(BrowserListingAnimation.animatesChanges(
            displayedLocation: "/A",
            location: "/A",
            itemCount: BrowserListingAnimation.maxAnimatedItems + 1,
            reduceMotion: false
        ))
        XCTAssertFalse(BrowserListingAnimation.animatesChanges(
            displayedLocation: "/A", location: "/A", itemCount: 12, reduceMotion: true
        ))
    }

    func testCascadeStaggersOnlyTheFirstItemsRightAfterAListingArrives() {
        XCTAssertEqual(BrowserCascade.delay(forIndex: 0, elapsedSinceListing: 0, reduceMotion: false), 0)
        let tenth = BrowserCascade.delay(forIndex: 10, elapsedSinceListing: 0.01, reduceMotion: false)
        XCTAssertEqual(tenth ?? -1, 10 * BrowserCascade.step, accuracy: 0.0001)
        XCTAssertNil(BrowserCascade.delay(
            forIndex: BrowserCascade.maxItems, elapsedSinceListing: 0, reduceMotion: false
        ))
        XCTAssertNil(BrowserCascade.delay(
            forIndex: 1, elapsedSinceListing: BrowserCascade.window, reduceMotion: false
        ))
        XCTAssertNil(BrowserCascade.delay(forIndex: 1, elapsedSinceListing: 0, reduceMotion: true))
    }

    func testWholeCascadeFinishesQuickly() {
        let lastDelay = Double(BrowserCascade.maxItems - 1) * BrowserCascade.step
        XCTAssertLessThan(lastDelay + Motion.Duration.standard, 0.7)
    }
}

@MainActor
final class BrowserPresentationTests: XCTestCase {
    func testLoadingIndicatorWording() {
        XCTAssertEqual(BrowserLoadingIndicator.title(for: nil), "Loading…")
        XCTAssertEqual(BrowserLoadingIndicator.title(for: .init(path: "/")), "Loading…")
        XCTAssertEqual(BrowserLoadingIndicator.title(for: .init(path: "/DCIM/Camera")), "Opening Camera…")
        XCTAssertNil(BrowserLoadingIndicator.detail(for: .init(path: "/DCIM/Camera")))
        XCTAssertEqual(
            BrowserLoadingIndicator.detail(
                for: .init(path: "/DCIM/Camera", itemCount: 2_003, fractionCompleted: 0.5)
            ),
            "\(1_002.formatted()) of \(2_003.formatted()) items"
        )
        XCTAssertEqual(
            BrowserLoadingIndicator.detail(for: .init(path: "/A", itemCount: 1, fractionCompleted: 1)),
            "1 of 1 item"
        )
    }

    func testEmptyStatesSpeakToTheirPane() {
        let device = BrowserEmptyStateView(kind: .emptyFolder(.device))
        let local = BrowserEmptyStateView(kind: .emptyFolder(.local))
        let search = BrowserEmptyStateView(kind: .noResults("cat"))
        XCTAssertEqual(device.title, "Empty Folder")
        XCTAssertTrue(device.message.contains("phone"))
        XCTAssertTrue(local.message.contains("this Mac"))
        XCTAssertNotEqual(device.message, local.message)
        XCTAssertEqual(search.title, "No Results")
        XCTAssertEqual(search.message, "No items match “cat”.")
    }
}
