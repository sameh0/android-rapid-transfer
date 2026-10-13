import Foundation
import XCTest
@testable import AndroidRapidTransferCore

final class LinuxUdevRulesTests: XCTestCase {
    private var packagedRulesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AndroidRapidTransferCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ARTCore
            .deletingLastPathComponent() // native
            .appendingPathComponent("AndroidRapidTransferLinux/packaging")
            .appendingPathComponent(LinuxUdevRules.fileName)
    }

    func testRulesMatchThePackagedFile() throws {
        let packaged = try String(contentsOf: packagedRulesURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
        XCTAssertEqual(LinuxUdevRules.lines, packaged)
    }

    func testCommandWritesExactlyTheRules() throws {
        let command = LinuxUdevRules.installCommand
        let writer = try XCTUnwrap(command.components(separatedBy: " | sudo tee ").first)
        XCTAssertTrue(command.contains("/etc/udev/rules.d/\(LinuxUdevRules.fileName)"))
        XCTAssertTrue(command.hasSuffix("sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=usb"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", writer]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), LinuxUdevRules.lines.joined(separator: "\n") + "\n")
    }
}
