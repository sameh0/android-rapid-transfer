import Foundation
import MTPKit
import XCTest
@testable import SwiftMTP

/// Shared fixtures for the SwiftMTPProvider tests.
class ProviderTestCase: XCTestCase {
    /// A zone with a UTC offset, so wall-clock vs instant mistakes show.
    let zone = TimeZone(identifier: "America/New_York")!
    let fixedNow = Date(timeIntervalSince1970: 1_714_979_289) // 2024-05-06T07:08:09Z
    let sid = UInt32(0x10001)

    func makeProvider(
        _ device: FakeMTPDevice,
        _ configure: (inout SwiftMTPProviderConfiguration) -> Void = { _ in }
    ) -> (SwiftMTPProvider, FakeDeviceFactory) {
        let factory = FakeDeviceFactory(device: device)
        let fixedNow = fixedNow
        var configuration = SwiftMTPProviderConfiguration(
            openDevice: { try factory.open() },
            timeZone: zone,
            now: { fixedNow }
        )
        configuration.bulkTimeout = 1
        configuration.transferChunkSize = 4096
        configuration.progressInterval = 0
        configuration.walkProgressInterval = 0
        configuration.sessionIDGenerator = { 1 }
        configure(&configuration)
        return (SwiftMTPProvider(configuration: configuration), factory)
    }

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMTPProviderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func walkInput(_ path: String, objectId: UInt32? = nil, storage: UInt32 = 0x10001,
                   skipDisallowed: Bool = false, skipHidden: Bool = false) -> DirectoryWalkInput {
        DirectoryWalkInput(storageId: storage, fullPath: path, objectId: objectId,
                           skipDisallowedFiles: skipDisallowed, skipHiddenFiles: skipHidden)
    }

    /// Drains the progress stream, then awaits the result.
    func run(_ operation: TransferOperation) async throws -> [TransferEvent] {
        var events: [TransferEvent] = []
        for await event in operation.progress { events.append(event) }
        let succeeded = try await operation.result.value
        XCTAssertTrue(succeeded)
        return events
    }

    /// Drains the progress stream and returns the error the result threw.
    func failure(of operation: TransferOperation, file: StaticString = #filePath, line: UInt = #line) async -> Error? {
        for await _ in operation.progress {}
        do {
            let value = try await operation.result.value
            XCTFail("transfer succeeded (\(value)) but a failure was expected", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    func callError(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) -> MTPCallError? {
        guard let call = error as? MTPCallError else {
            XCTFail("expected MTPCallError, got \(String(describing: error))", file: file, line: line)
            return nil
        }
        return call
    }

    func assertThrowsCall<T>(
        _ type: MTPErrorType, message: String? = nil, contains: String? = nil,
        file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(type.rawValue)", file: file, line: line)
        } catch {
            guard let call = callError(error, file: file, line: line) else { return }
            XCTAssertEqual(call.type, type, "\(call)", file: file, line: line)
            if let message { XCTAssertEqual(call.message, message, file: file, line: line) }
            if let contains {
                XCTAssertTrue(call.message.contains(contains), "\(call.message) lacks \(contains)", file: file, line: line)
            }
        }
    }

    func progressEvents(_ events: [TransferEvent]) -> [TransferProgressInfo] {
        events.compactMap { if case let .progress(info) = $0 { info } else { nil } }
    }

    func preprocessEvents(_ events: [TransferEvent]) -> [TransferPreprocessData] {
        events.compactMap { if case let .preprocess(info) = $0 { info } else { nil } }
    }

    func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }

    func patternedData(_ count: Int, seed: UInt8 = 3) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ Int(seed)) })
    }

    func writeFile(_ url: URL, _ data: Data, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }
}

/// Collects walk progress callbacks from the I/O thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WalkProgress] = []

    func append(_ progress: WalkProgress) { lock.withLock { items.append(progress) } }
    var all: [WalkProgress] { lock.withLock { items } }
}
