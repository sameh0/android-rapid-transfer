import Foundation
import XCTest

/// Exercises `verify_bundle_layout` and `install_acknowledgements` from
/// `Scripts/release-config.sh`, which every packaging script relies on.
final class ReleaseLayoutVerificationTests: XCTestCase {
    private var root: URL!
    private var app: URL { root.appending(path: "Test.app", directoryHint: .isDirectory) }
    private var contents: URL { app.appending(path: "Contents", directoryHint: .isDirectory) }

    /// Tests/AndroidRapidTransferCoreTests/<file> → the package root.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let config = packageRoot.appending(path: "Scripts/release-config.sh")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ReleaseLayoutVerificationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        // What the packaging scripts assemble: the executable, Sparkle, the notices.
        try write("MacOS/AndroidRapidTransfer", "#!/bin/sh\n", executable: true)
        try write("Frameworks/Sparkle.framework/Versions/B/Sparkle", "")
        try write("Resources/Acknowledgements.txt", "ACKNOWLEDGEMENTS\n")
        try write("Info.plist", "")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ text: String, executable: Bool = false) throws {
        let url = contents.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private struct Outcome {
        let status: Int32
        let output: String
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private func verify(extraArguments: [String] = []) throws -> Outcome {
        try run("/bin/bash", [
            "-c",
            #"set -euo pipefail; source "$1"; shift; verify_bundle_layout "$@""#,
            "verify",
            Self.config.path,
            app.path,
        ] + extraArguments)
    }

    func testTheExpectedLayoutPasses() throws {
        let outcome = try verify()
        XCTAssertEqual(outcome.status, 0, outcome.output)
        XCTAssertTrue(outcome.output.contains("Bundle layout: verified."), outcome.output)
    }

    func testStrayCodeFailsTheCheck() throws {
        for relative in ["MacOS/helper", "Frameworks/libextra.dylib", "Frameworks/Other.framework/Other"] {
            try write(relative, "", executable: relative.hasPrefix("MacOS"))
            let outcome = try verify()
            let top = relative.split(separator: "/").prefix(2).joined(separator: "/")
            XCTAssertNotEqual(outcome.status, 0, "\(relative) was allowed")
            XCTAssertTrue(outcome.output.contains("unexpected \(top)"), outcome.output)
            try FileManager.default.removeItem(at: contents.appending(path: top))
        }
    }

    func testAMissingExecutableFailsTheCheck() throws {
        try FileManager.default.removeItem(at: contents.appending(path: "MacOS/AndroidRapidTransfer"))
        let outcome = try verify()
        XCTAssertNotEqual(outcome.status, 0)
        XCTAssertTrue(outcome.output.contains("missing MacOS/AndroidRapidTransfer"), outcome.output)
    }

    func testExtraArgumentsAreAUsageError() throws {
        let outcome = try verify(extraArguments: ["1"])
        XCTAssertEqual(outcome.status, 2, outcome.output)
        XCTAssertTrue(outcome.output.contains("Usage: verify_bundle_layout <App.app>"), outcome.output)
    }

    func testInstallAcknowledgementsCopiesTheNotices() throws {
        let project = root.appending(path: "Project", directoryHint: .isDirectory)
        let resources = project.appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("BASE\n".utf8).write(to: resources.appending(path: "Acknowledgements.txt"))
        let target = root.appending(path: "Target.app/Contents", directoryHint: .isDirectory)
        let install = #"set -euo pipefail; source "$1"; shift; install_acknowledgements "$@""#

        let extra = try run("/bin/bash", ["-c", install, "install", Self.config.path, project.path, target.path, "1"])
        XCTAssertEqual(extra.status, 2, extra.output)

        let outcome = try run("/bin/bash", ["-c", install, "install", Self.config.path, project.path, target.path])
        XCTAssertEqual(outcome.status, 0, outcome.output)
        let installed = try FileManager.default.contentsOfDirectory(atPath: target.appending(path: "Resources").path)
        XCTAssertEqual(installed, ["Acknowledgements.txt"])
    }

    func testInstallAppIconCopiesTheIconAndRequiresIt() throws {
        let project = root.appending(path: "Project", directoryHint: .isDirectory)
        let resources = project.appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let target = root.appending(path: "Target.app/Contents", directoryHint: .isDirectory)
        let install = #"set -euo pipefail; source "$1"; shift; install_app_icon "$@""#

        let missing = try run("/bin/bash", ["-c", install, "install", Self.config.path, project.path, target.path])
        XCTAssertNotEqual(missing.status, 0)
        XCTAssertTrue(missing.output.contains("make-app-icon.sh"), missing.output)

        try Data("icns".utf8).write(to: resources.appending(path: "AppIcon.icns"))
        let outcome = try run("/bin/bash", ["-c", install, "install", Self.config.path, project.path, target.path])
        XCTAssertEqual(outcome.status, 0, outcome.output)
        let installed = try FileManager.default.contentsOfDirectory(atPath: target.appending(path: "Resources").path)
        XCTAssertEqual(installed, ["AppIcon.icns"])
    }

    /// Both packaging scripts install the icon and name it in Info.plist.
    func testPackagingScriptsShipTheAppIcon() throws {
        for script in ["make-app.sh", "Scripts/package-release.sh"] {
            let text = try String(contentsOf: Self.packageRoot.appending(path: script), encoding: .utf8)
            XCTAssertTrue(text.contains("install_app_icon"), script)
            XCTAssertTrue(text.contains("<key>CFBundleIconFile</key>"), script)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.packageRoot.appending(path: "Resources/AppIcon.icns").path))
    }
}
