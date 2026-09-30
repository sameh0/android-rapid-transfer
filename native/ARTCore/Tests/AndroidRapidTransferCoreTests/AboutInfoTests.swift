import Foundation
import XCTest
@testable import AndroidRapidTransferCore

final class AboutInfoTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026

    func testPackagedBuildShowsItsBuildNumberAndCopyright() {
        let info = AboutInfo(
            info: [
                "CFBundleDisplayName": "Android Rapid Transfer",
                "CFBundleVersion": "57",
                "NSHumanReadableCopyright": "Copyright © 2026 Sameh."
            ],
            version: "0.2.0",
            now: date
        )
        XCTAssertEqual(info.name, "Android Rapid Transfer")
        XCTAssertEqual(info.build, "57")
        XCTAssertEqual(info.versionLine, "Version 0.2.0 (57)")
        XCTAssertEqual(info.copyright, "Copyright © 2026 Sameh.")
        XCTAssertEqual(
            info.diagnosticsLine(macOSVersion: "Version 15.1"),
            "Android Rapid Transfer 0.2.0 (57), macOS Version 15.1"
        )
    }

    func testUnbundledRunDescribesItselfAsADevelopmentBuild() {
        let info = AboutInfo(info: nil, version: "0.2.0-beta.1", now: date)
        XCTAssertEqual(info.name, AppIdentity.fallbackName)
        XCTAssertNil(info.build)
        XCTAssertEqual(info.versionLine, "Version 0.2.0-beta.1 (development build)")
        XCTAssertEqual(info.copyright, "Copyright © 2026 \(AppIdentity.copyrightHolder).")
        XCTAssertTrue(info.diagnosticsLine(macOSVersion: "15").contains("(dev)"))
    }

    func testBlankValuesFallBack() {
        let info = AboutInfo(
            info: ["CFBundleVersion": "  ", "NSHumanReadableCopyright": ""],
            version: "1.0.0",
            now: date
        )
        XCTAssertNil(info.build)
        XCTAssertTrue(info.copyright.hasPrefix("Copyright © 2026"))
    }
}
