@testable import AndroidRapidTransfer
import CoreGraphics
import XCTest

@MainActor
final class OnboardingTests: XCTestCase {
    func testPagesRunFromWelcomeThroughThreeSetupStepsToDone() {
        XCTAssertEqual(OnboardingPage.allCases, [.welcome, .unlock, .plugIn, .fileTransfer, .done])
        XCTAssertEqual(OnboardingPage.allCases.compactMap(\.setupStep), [1, 2, 3])
        XCTAssertEqual(OnboardingPage.setupStepCount, 3)
        XCTAssertNil(OnboardingPage.welcome.setupStep)
        XCTAssertNil(OnboardingPage.done.setupStep)
        XCTAssertTrue(OnboardingPage.welcome.isFirst)
        XCTAssertTrue(OnboardingPage.done.isLast)
    }

    func testConnectionHelpStartsAtTheFirstSetupStep() {
        XCTAssertEqual(OnboardingPage.connect.setupStep, 1)
        let coordinator = OnboardingCoordinator()
        coordinator.show(page: .connect)
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.page, .unlock)
    }

    func testAdvanceWalksEveryPageThenCloses() {
        let coordinator = OnboardingCoordinator()
        coordinator.show()
        var visited = [coordinator.page]
        while !coordinator.page.isLast {
            coordinator.advance()
            XCTAssertTrue(coordinator.isMovingForward)
            visited.append(coordinator.page)
        }
        XCTAssertEqual(visited, OnboardingPage.allCases)
        XCTAssertTrue(coordinator.isPresented)

        coordinator.advance()
        XCTAssertFalse(coordinator.isPresented, "Continuing from the last page closes the sheet")
        XCTAssertEqual(coordinator.page, .done)
    }

    func testGoingBackStopsAtTheFirstPageAndRecordsDirection() {
        let coordinator = OnboardingCoordinator()
        coordinator.show(page: .plugIn)
        coordinator.goBack()
        XCTAssertEqual(coordinator.page, .unlock)
        XCTAssertFalse(coordinator.isMovingForward)
        coordinator.goBack()
        coordinator.goBack()
        XCTAssertEqual(coordinator.page, .welcome)
    }

    func testJumpingToAPageSetsTheDirection() {
        let coordinator = OnboardingCoordinator()
        coordinator.show()
        coordinator.go(to: .fileTransfer)
        XCTAssertEqual(coordinator.page, .fileTransfer)
        XCTAssertTrue(coordinator.isMovingForward)
        coordinator.go(to: .unlock)
        XCTAssertFalse(coordinator.isMovingForward)
        // Re-selecting the current page changes nothing.
        coordinator.go(to: .unlock)
        XCTAssertFalse(coordinator.isMovingForward)
    }

    func testShowingAgainStartsFreshAndDismissCloses() {
        let coordinator = OnboardingCoordinator()
        coordinator.show(page: .done)
        coordinator.goBack()
        coordinator.dismiss()
        XCTAssertFalse(coordinator.isPresented)
        coordinator.show()
        XCTAssertEqual(coordinator.page, .welcome)
        XCTAssertTrue(coordinator.isMovingForward)
    }

    func testFlightArcStartsAtThePhoneAndLandsOnTheMac() {
        let arc = OnboardingHeroView.flightPath
        XCTAssertEqual(arc.point(at: 0), arc.from)
        XCTAssertEqual(arc.point(at: 1), arc.to)
        // The arc rises above both ends on its way across.
        let middle = arc.point(at: 0.5)
        XCTAssertLessThan(middle.y, min(arc.from.y, arc.to.y))
        XCTAssertGreaterThan(middle.x, arc.from.x)
        XCTAssertLessThan(middle.x, arc.to.x)
        // It stays inside the illustration.
        for step in 0...10 {
            let point = arc.point(at: CGFloat(step) / 10)
            XCTAssertGreaterThanOrEqual(point.y, 0)
            XCTAssertLessThanOrEqual(point.x, OnboardingHeroView.size.width)
        }
    }

    func testPaletteTilesWrapForAnyIndex() {
        XCTAssertEqual(OnboardingPalette.tile(0), OnboardingPalette.tile(6))
        XCTAssertEqual(OnboardingPalette.tile(-1), OnboardingPalette.tile(5))
    }
}
