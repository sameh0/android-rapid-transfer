import Foundation

/// Who holds a USB interface (or device) open, as IOUSBHostFamily records it
/// in the I/O Registry property `UsbExclusiveOwner` while a client has it
/// open: `"pid 19641, ptpcamerad"` for a user-space process, or the class
/// name of a kernel driver (for example `"AppleUSBACMControl"`).
///
/// A user client's `IOUserClientCreator` has the same "pid N, name" form.
/// Parsing is platform-neutral so it can be tested anywhere; only reading the
/// registry needs IOKit (`USBDeviceDiscovery.claimHolder(ofInterface:)`).
public enum USBExclusiveOwner: Equatable, Sendable, CustomStringConvertible {
    case process(pid: Int32, name: String)
    case driver(className: String)

    /// The I/O Registry property IOUSBHostFamily sets on an opened interface
    /// or device.
    public static let registryKey = "UsbExclusiveOwner"

    /// Parses the property's value; nil when it is missing or empty.
    public init?(registryValue: String?) {
        guard let value = registryValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.hasPrefix("pid ") {
            let rest = value.dropFirst("pid ".count)
            let parts = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces)), pid > 0 else {
                self = .driver(className: value)
                return
            }
            let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            self = .process(pid: pid, name: name.isEmpty ? "process \(pid)" : name)
        } else {
            self = .driver(className: value)
        }
    }

    public var processID: Int32? {
        if case let .process(pid, _) = self { return pid }
        return nil
    }

    /// "ptpcamerad (pid 19641)" or "AppleUSBACMControl (kernel driver)". The
    /// app parses this form back out of the error text, so keep the two
    /// in step (`DeviceAccessProblem.holder`).
    public var description: String {
        switch self {
        case let .process(pid, name): "\(name) (pid \(pid))"
        case let .driver(className): "\(className) (kernel driver)"
        }
    }

    /// "ptpcamerad (pid 19641) is using the phone", the same phrase the Linux
    /// backend uses (`USBDeviceHolder.busyMessage`).
    public var busyMessage: String { "\(description) is using the phone" }
}

extension MTPTransportError {
    /// The text used when the claim failed because the interface is taken
    /// but the registry does not say by whom.
    public static let unknownHolderMessage = "another program or driver has claimed the phone's MTP interface"

    /// This claim failure re-expressed as "the interface is taken": kind
    /// `.exclusiveAccess` (whatever the OS status was, which is kept), with
    /// the holder named in the message.
    public func claimed(by owner: USBExclusiveOwner?) -> MTPTransportError {
        MTPTransportError(.exclusiveAccess, status: status,
                          "\(message): \(owner?.busyMessage ?? Self.unknownHolderMessage)")
    }
}

/// The retry policy for claiming an interface on macOS, separated from
/// IOUSBHost so it can be tested with a scripted attempt.
///
/// Every failed claim is logged with its status and kind, and the
/// interface's holder is read from the registry (`owner`: its
/// `UsbExclusiveOwner`, or the creator of a user client attached to it). A
/// claim is retried (nothing is held between attempts, and the device is
/// never reset) when:
/// - the interface is taken: the OS said so (`.exclusiveAccess`), or the
///   registry names a holder, whatever status the claim failed with (another
///   client's open does not always come back as kIOReturnExclusiveAccess);
/// - or the status is one of `retryableStatuses` (on macOS,
///   kIOReturnInternalError, which a Samsung phone's interface returned right
///   after macOS's Image Capture agent let go of it).
///
/// Once the delays are spent a taken interface is rethrown as
/// `.exclusiveAccess` naming the holder, so the app can explain it rather
/// than ask for a replug; anything else is rethrown as it was. Any other
/// failure is rethrown at once.
public enum USBClaimRetry {
    public static func run<T>(retryDelays: [TimeInterval],
                              retryableStatuses: Set<Int32> = [],
                              sleep: (TimeInterval) -> Void,
                              log: ((String) -> Void)?,
                              owner: () -> String?,
                              _ attempt: () throws -> T) throws -> T {
        var failures = 0
        while true {
            do {
                return try attempt()
            } catch let error as MTPTransportError where error.kind != .noDevice {
                failures += 1
                let ownerValue = owner()
                let holder = USBExclusiveOwner(registryValue: ownerValue)
                log?("open attempt \(failures) failed: \(error); holder: \(ownerValue.map { "\"\($0)\"" } ?? "none")")
                let taken = error.kind == .exclusiveAccess || holder != nil
                let retryable = taken || error.status.map(retryableStatuses.contains) == true
                guard retryable else { throw error }
                guard failures <= retryDelays.count else { throw taken ? error.claimed(by: holder) : error }
                let delay = retryDelays[failures - 1]
                log?("retrying the claim in \(delay) s (no reset)")
                sleep(delay)
            }
        }
    }
}
