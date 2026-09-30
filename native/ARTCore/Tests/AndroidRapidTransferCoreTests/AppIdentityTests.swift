import Foundation
import XCTest
@testable import AndroidRapidTransferCore

/// `AppIdentity` (read by the app) and `Scripts/release-config.sh` (read by the
/// packaging scripts that write the Info.plist) must describe the same app.
final class AppIdentityTests: XCTestCase {
    private func releaseConfig() throws -> [String: String] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AndroidRapidTransferCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root (ARTCore)
            .deletingLastPathComponent() // native
            .appending(path: "AndroidRapidTransfer") // the app package, which owns the packaging scripts
        let script = try String(
            contentsOf: packageRoot.appending(path: "Scripts/release-config.sh"),
            encoding: .utf8
        )
        var values: [String: String] = [:]
        for line in script.split(separator: "\n") {
            // Plain assignments only: NAME="value" at the start of a line.
            guard let match = line.wholeMatch(of: /([A-Z_]+)="([^"$]*)"/) else { continue }
            values[String(match.1)] = String(match.2)
        }
        return values
    }

    func testNameMatchesThePackagingScripts() throws {
        let config = try releaseConfig()
        XCTAssertEqual(AppIdentity.fallbackName, "Android Rapid Transfer")
        XCTAssertEqual(config["APP_DISPLAY_NAME"], AppIdentity.fallbackName)
    }

    func testBundleIdentifierMatchesThePackagingScripts() throws {
        let config = try releaseConfig()
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.sameh.AndroidRapidTransfer")
        XCTAssertEqual(config["APP_BUNDLE_ID"], AppIdentity.bundleIdentifier)
    }

    func testCopyrightHolderMatchesThePackagingScriptsAndLicense() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AndroidRapidTransferCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root (ARTCore)
            .deletingLastPathComponent() // native
            .appending(path: "AndroidRapidTransfer") // the app package, which owns the packaging scripts
        let script = try String(
            contentsOf: packageRoot.appending(path: "Scripts/release-config.sh"),
            encoding: .utf8
        )
        // COPYRIGHT_HOLDER="${COPYRIGHT_HOLDER:-<default>}"
        let match = try XCTUnwrap(script.firstMatch(of: /COPYRIGHT_HOLDER="\$\{COPYRIGHT_HOLDER:-([^}]*)\}"/))
        XCTAssertEqual(String(match.1), AppIdentity.copyrightHolder)

        let license = try String(
            contentsOf: packageRoot.appending(path: "../../LICENSE").standardizedFileURL,
            encoding: .utf8
        )
        XCTAssertTrue(license.contains("-present \(AppIdentity.copyrightHolder)"))
    }

    func testUpdateFeedLivesInTheRepository() throws {
        let config = try releaseConfig()
        let feed = try XCTUnwrap(config["SPARKLE_FEED_URL"])
        XCTAssertTrue(
            feed.hasPrefix(AppIdentity.repositoryURL.absoluteString + "/releases/"),
            "\(feed) is not under \(AppIdentity.repositoryURL)"
        )
    }

    func testInfoPlistNameWinsOverTheFallback() {
        XCTAssertEqual(
            AppIdentity.name(from: ["CFBundleDisplayName": "Android Rapid Transfer"]),
            "Android Rapid Transfer"
        )
        XCTAssertEqual(AppIdentity.name(from: nil), AppIdentity.fallbackName)
    }

    func testSupportDirectoryIsNamedByBundleIdentifier() {
        let home = URL(fileURLWithPath: "/tmp/art-home", isDirectory: true)
        XCTAssertEqual(
            AppIdentity.supportDirectory(home: home).path,
            "/tmp/art-home/Library/Application Support/com.sameh.AndroidRapidTransfer"
        )
    }
}
