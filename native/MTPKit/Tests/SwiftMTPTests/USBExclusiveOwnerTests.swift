import Foundation
import MTPKit
import XCTest
@testable import SwiftMTP

/// Naming who holds a phone's interface (`UsbExclusiveOwner`) and the claim
/// retry policy built on it.
final class USBExclusiveOwnerTests: XCTestCase {
    // MARK: - Parsing the registry value

    func testProcessOwnerIsParsedFromPidAndName() {
        let owner = USBExclusiveOwner(registryValue: "pid 19641, ptpcamerad")
        XCTAssertEqual(owner, .process(pid: 19641, name: "ptpcamerad"))
        XCTAssertEqual(owner?.processID, 19641)
        XCTAssertEqual(owner?.description, "ptpcamerad (pid 19641)")
        XCTAssertEqual(owner?.busyMessage, "ptpcamerad (pid 19641) is using the phone")
    }

    func testProcessNameMayContainSpacesAndPadding() {
        XCTAssertEqual(USBExclusiveOwner(registryValue: "  pid 812,  Image Capture \n"),
                       .process(pid: 812, name: "Image Capture"))
    }

    func testProcessWithoutANameIsNamedByItsPid() {
        XCTAssertEqual(USBExclusiveOwner(registryValue: "pid 77"), .process(pid: 77, name: "process 77"))
        XCTAssertEqual(USBExclusiveOwner(registryValue: "pid 77, "), .process(pid: 77, name: "process 77"))
    }

    func testKernelDriverOwnerIsItsClassName() {
        let owner = USBExclusiveOwner(registryValue: "AppleUSBACMControl")
        XCTAssertEqual(owner, .driver(className: "AppleUSBACMControl"))
        XCTAssertNil(owner?.processID)
        XCTAssertEqual(owner?.description, "AppleUSBACMControl (kernel driver)")
    }

    func testMalformedPidIsKeptAsTextRatherThanDropped() {
        XCTAssertEqual(USBExclusiveOwner(registryValue: "pid x, odd"), .driver(className: "pid x, odd"))
        XCTAssertEqual(USBExclusiveOwner(registryValue: "pid 0, kernel_task"), .driver(className: "pid 0, kernel_task"))
    }

    func testMissingOrEmptyValueHasNoOwner() {
        XCTAssertNil(USBExclusiveOwner(registryValue: nil))
        XCTAssertNil(USBExclusiveOwner(registryValue: ""))
        XCTAssertNil(USBExclusiveOwner(registryValue: "   "))
    }

    func testClaimedErrorKeepsTheStatusAndNamesTheHolder() {
        let error = MTPTransportError(.notPermitted, status: IOReturnCode.notPermitted,
                                      "opening IOUSBHostInterface: kIOReturnNotPermitted [domain]")
        let claimed = error.claimed(by: .process(pid: 19641, name: "ptpcamerad"))
        XCTAssertEqual(claimed.kind, .exclusiveAccess)
        XCTAssertEqual(claimed.status, IOReturnCode.notPermitted)
        XCTAssertEqual(claimed.message,
                       "opening IOUSBHostInterface: kIOReturnNotPermitted [domain]: ptpcamerad (pid 19641) is using the phone")
        XCTAssertTrue(claimed.description.contains("(exclusiveAccess"), "the app recognises the busy case by this marker")
        XCTAssertTrue(error.claimed(by: nil).message.hasSuffix(MTPTransportError.unknownHolderMessage))
    }

    // MARK: - Claim retry

    private struct Run {
        var result: Result<Int, Error>
        var slept: [TimeInterval]
        var ownerReads: Int
        var log: [String]
    }

    private func runClaim(failures: [MTPTransportError], owner: String?,
                          delays: [TimeInterval] = [0.25, 0.5, 1.0, 2.0]) -> Run {
        var remaining = failures
        var calls = 0
        var slept: [TimeInterval] = []
        var ownerReads = 0
        var log: [String] = []
        let result = Result {
            try USBClaimRetry.run(retryDelays: delays, sleep: { slept.append($0) }, log: { log.append($0) },
                                  owner: { ownerReads += 1; return owner }) { () -> Int in
                calls += 1
                if !remaining.isEmpty { throw remaining.removeFirst() }
                return calls
            }
        }
        return Run(result: result, slept: slept, ownerReads: ownerReads, log: log)
    }

    private static let exclusive = MTPTransportError(.exclusiveAccess, status: IOReturnCode.exclusiveAccess,
                                                     "opening IOUSBHostInterface: kIOReturnExclusiveAccess")
    private static let notPermitted = MTPTransportError(.notPermitted, status: IOReturnCode.notPermitted,
                                                        "opening IOUSBHostInterface: kIOReturnNotPermitted")

    func testBusyClaimIsRetriedThenSucceeds() throws {
        let run = runClaim(failures: [Self.exclusive, Self.exclusive], owner: "pid 19641, ptpcamerad")
        XCTAssertEqual(try run.result.get(), 3)
        XCTAssertEqual(run.slept, [0.25, 0.5])
    }

    func testBusyClaimThatNeverFreesUpNamesTheHolder() {
        let run = runClaim(failures: Array(repeating: Self.exclusive, count: 5), owner: "pid 19641, ptpcamerad")
        XCTAssertEqual(run.slept, [0.25, 0.5, 1.0, 2.0])
        guard case let .failure(error as MTPTransportError) = run.result else { return XCTFail("\(run.result)") }
        XCTAssertEqual(error.kind, .exclusiveAccess)
        XCTAssertEqual(error.status, IOReturnCode.exclusiveAccess)
        XCTAssertTrue(error.message.hasSuffix("ptpcamerad (pid 19641) is using the phone"), error.message)
    }

    func testBusyClaimWithNoRegistryOwnerSaysSo() {
        let run = runClaim(failures: Array(repeating: Self.exclusive, count: 5), owner: nil)
        guard case let .failure(error as MTPTransportError) = run.result else { return XCTFail("\(run.result)") }
        XCTAssertEqual(error.kind, .exclusiveAccess)
        XCTAssertTrue(error.message.hasSuffix(MTPTransportError.unknownHolderMessage))
    }

    /// Another client's open does not always fail with kIOReturnExclusiveAccess:
    /// when the registry names an owner, any claim failure means "taken".
    func testOtherClaimFailureWhileTheRegistryNamesAnOwnerIsTreatedAsBusy() {
        let run = runClaim(failures: Array(repeating: Self.notPermitted, count: 5), owner: "pid 19641, ptpcamerad")
        XCTAssertEqual(run.slept, [0.25, 0.5, 1.0, 2.0])
        guard case let .failure(error as MTPTransportError) = run.result else { return XCTFail("\(run.result)") }
        XCTAssertEqual(error.kind, .exclusiveAccess)
        XCTAssertEqual(error.status, IOReturnCode.notPermitted, "the OS status is kept for diagnosis")
        XCTAssertTrue(error.message.contains("kIOReturnNotPermitted"))
        XCTAssertTrue(error.message.hasSuffix("ptpcamerad (pid 19641) is using the phone"))
    }

    func testOtherClaimFailureWithNoOwnerFailsAtOnce() {
        let run = runClaim(failures: [Self.notPermitted], owner: nil)
        XCTAssertEqual(run.slept, [])
        XCTAssertEqual(run.ownerReads, 1)
        guard case let .failure(error as MTPTransportError) = run.result else { return XCTFail("\(run.result)") }
        XCTAssertEqual(error, Self.notPermitted, "rethrown unchanged")
    }

    func testVanishedInterfaceFailsAtOnceWithoutConsultingTheRegistry() {
        let gone = MTPTransportError(.noDevice, "interface 7 is no longer in the I/O Registry")
        let run = runClaim(failures: [gone], owner: "pid 19641, ptpcamerad")
        XCTAssertEqual(run.slept, [])
        XCTAssertEqual(run.ownerReads, 0)
        guard case let .failure(error as MTPTransportError) = run.result else { return XCTFail("\(run.result)") }
        XCTAssertEqual(error, gone)
    }

    func testEveryFailedClaimIsLoggedWithItsStatusAndOwner() {
        let run = runClaim(failures: [Self.notPermitted], owner: nil)
        XCTAssertEqual(run.log.count, 1)
        XCTAssertTrue(run.log[0].contains("open attempt 1 failed"))
        XCTAssertTrue(run.log[0].contains("notPermitted"))
        #if os(macOS)
        XCTAssertTrue(run.log[0].contains("IOReturn 0xe00002e2"), run.log[0])
        #endif
        XCTAssertTrue(run.log[0].contains("holder: none"))

        let busy = runClaim(failures: [Self.exclusive], owner: "pid 5, ptpcamerad")
        XCTAssertTrue(busy.log[0].contains("holder: \"pid 5, ptpcamerad\""), busy.log[0])
        XCTAssertTrue(busy.log[1].contains("retrying the claim in 0.25 s (no reset)"))
    }

    // MARK: kIOReturnInternalError

    private static let internalError = MTPTransportError(.io, status: IOReturnCode.internalError,
                                                         "opening IOUSBHostInterface: kIOReturnInternalError [IOUSBHostErrorDomain]")

    func testInternalErrorIsNamedAndKeepsKindIO() {
        XCTAssertEqual(IOReturnCode.name(IOReturnCode.internalError), "kIOReturnInternalError")
        XCTAssertEqual(IOReturnCode.kind(IOReturnCode.internalError), .io,
                       "outside the claim an internal error stays an I/O failure")
    }

    func testListedStatusIsRetriedOnTheClaim() throws {
        var remaining = [Self.internalError, Self.internalError]
        var slept: [TimeInterval] = []
        let value = try USBClaimRetry.run(retryDelays: [0.25, 0.5, 1.0, 2.0],
                                          retryableStatuses: [IOReturnCode.internalError],
                                          sleep: { slept.append($0) }, log: nil, owner: { nil }) { () -> Int in
            if !remaining.isEmpty { throw remaining.removeFirst() }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(slept, [0.25, 0.5])
    }

    func testListedStatusThatPersistsIsRethrownAsItWasWithoutAHolder() {
        var slept: [TimeInterval] = []
        let result = Result {
            try USBClaimRetry.run(retryDelays: [0.25, 0.5], retryableStatuses: [IOReturnCode.internalError],
                                  sleep: { slept.append($0) }, log: nil, owner: { nil }) { () -> Int in
                throw Self.internalError
            }
        }
        XCTAssertEqual(slept, [0.25, 0.5])
        guard case let .failure(error as MTPTransportError) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(error, Self.internalError, "not dressed up as a busy interface when nobody holds it")
    }

    func testListedStatusWithAHolderIsReportedAsTaken() {
        let result = Result {
            try USBClaimRetry.run(retryDelays: [0.25], retryableStatuses: [IOReturnCode.internalError],
                                  sleep: { _ in }, log: nil, owner: { "pid 19641, ptpcamerad" }) { () -> Int in
                throw Self.internalError
            }
        }
        guard case let .failure(error as MTPTransportError) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(error.kind, .exclusiveAccess)
        XCTAssertEqual(error.status, IOReturnCode.internalError)
        XCTAssertTrue(error.message.hasSuffix("ptpcamerad (pid 19641) is using the phone"))
    }

    func testUnlistedStatusIsNotRetried() {
        var slept: [TimeInterval] = []
        let result = Result {
            try USBClaimRetry.run(retryDelays: [0.25], sleep: { slept.append($0) }, log: nil, owner: { nil }) { () -> Int in
                throw Self.internalError
            }
        }
        XCTAssertEqual(slept, [])
        if case .success = result { XCTFail("expected a failure") }
    }
}
