@testable import AndroidRapidTransfer
import SwiftUI
import XCTest

final class MotionTests: XCTestCase {
    private let full = MotionPolicy(reduceMotion: false)
    private let reduced = MotionPolicy(reduceMotion: true)

    func testAnimationsPassThroughWhenMotionIsAllowed() {
        for animation in [Motion.snappy, Motion.bouncy, Motion.gentle, Motion.celebrate, Motion.fade] {
            XCTAssertEqual(full.animation(animation), animation)
        }
        XCTAssertNil(full.animation(nil))
    }

    func testReduceMotionMakesEveryAnimationInstant() {
        for animation in [Motion.snappy, Motion.bouncy, Motion.gentle, Motion.celebrate, Motion.fade] {
            XCTAssertNil(reduced.animation(animation))
        }
    }

    func testReduceMotionZeroesDurations() {
        XCTAssertEqual(full.duration(Motion.Duration.standard), Motion.Duration.standard)
        for duration in [Motion.Duration.quick, Motion.Duration.standard, Motion.Duration.slow] {
            XCTAssertEqual(reduced.duration(duration), 0)
        }
    }

    func testReduceMotionDisablesMatchedGeometry() {
        XCTAssertTrue(full.allowsMatchedGeometry)
        XCTAssertFalse(reduced.allowsMatchedGeometry)
    }

    func testDurationsAreOrdered() {
        XCTAssertLessThan(Motion.Duration.quick, Motion.Duration.standard)
        XCTAssertLessThan(Motion.Duration.standard, Motion.Duration.slow)
    }

    @MainActor
    func testWithMotionAlwaysRunsTheChange() {
        var changed = 0
        withMotion(.bouncy, policy: reduced) { changed += 1 }
        withMotion(.bouncy, policy: full) { changed += 1 }
        XCTAssertEqual(changed, 2)
    }

    @MainActor
    func testCurrentPolicyFollowsTheSystemSetting() {
        XCTAssertEqual(
            MotionPolicy.current.reduceMotion,
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}
