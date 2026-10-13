import Foundation
#if os(macOS)
import Darwin
import SwiftMTP
#endif

/// Stops macOS's Image Capture agent (`ptpcamerad`) when it holds the phone,
/// on the user's click only.
///
/// ptpcamerad is a per-user launchd agent
/// (`/System/Library/LaunchAgents/com.apple.ptpcamerad.plist`): it is not
/// kept alive, launchd starts it on demand when something asks for its Mach
/// service `com.apple.ptpcamerad`, so stopping it costs nothing — Image
/// Capture and Photos get it back the next time they need it. It opens every
/// phone that offers a still-image (PTP-class) interface as soon as the phone
/// is plugged in, and Samsung's MTP interface is one, so it can hold a Samsung
/// phone with no app open. Because launchd may start it again at any moment,
/// the caller retries the connection immediately after a release.
///
/// Safety: only a process that is ptpcamerad (by name, and by path when the
/// path is readable), running as this user, is ever signalled, and its
/// identity is checked again before the escalation to SIGKILL (a pid can be
/// reused). Observed on a Mac holding a Samsung phone: ptpcamerad ignored
/// SIGTERM and kept the phone, and only SIGKILL released it; so SIGTERM gets a
/// short grace period, then SIGKILL, and success is reported only once the
/// process is gone and no USB device or interface still names it as
/// `UsbExclusiveOwner`.
///
/// Every system call goes through an injectable seam; tests never signal a
/// real process.
public struct ImageCaptureAgentRelease: Sendable {
    public struct ProcessRecord: Equatable, Sendable {
        /// The short process name (`p_comm`).
        public var name: String
        /// The executable's path, when readable.
        public var path: String?
        /// Real and effective user IDs.
        public var realUserID: UInt32
        public var effectiveUserID: UInt32

        public init(name: String, path: String?, realUserID: UInt32, effectiveUserID: UInt32) {
            self.name = name
            self.path = path
            self.realUserID = realUserID
            self.effectiveUserID = effectiveUserID
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The agent exited and no longer holds any USB device.
        case released(forced: Bool)
        /// The process had already exited.
        case alreadyGone
        /// The pid is not ptpcamerad (any more); nothing was signalled.
        case notImageCaptureAgent(name: String)
        /// It runs as another user; nothing was signalled.
        case ownedByAnotherUser(userName: String?)
        /// The signal could not be sent (errno).
        case signalFailed(errno: Int32)
        /// Still running after SIGTERM and SIGKILL.
        case stillRunning
        /// Exited, yet a USB device or interface still names it as owner.
        case stillHoldsPhone

        public var succeeded: Bool {
            switch self {
            case .released, .alreadyGone: true
            default: false
            }
        }

        /// What to tell the user when the release did not work; nil when it did.
        public var failureMessage: String? {
            switch self {
            case .released, .alreadyGone:
                return nil
            case let .notImageCaptureAgent(name):
                return String(localized: "\(AppIdentity.name) didn’t stop anything: the program holding the phone is now “\(name)”, not macOS’s Image Capture service.")
            case let .ownedByAnotherUser(userName):
                if let userName {
                    return String(localized: "macOS’s Image Capture service holding the phone belongs to another user on this Mac (\(userName)), so \(AppIdentity.name) can’t stop it. Log out that user or restart the Mac, then click Retry.")
                }
                return String(localized: "macOS’s Image Capture service holding the phone belongs to another user on this Mac, so \(AppIdentity.name) can’t stop it. Log out that user or restart the Mac, then click Retry.")
            case let .signalFailed(code):
                return String(localized: "macOS’s Image Capture service didn’t stop: \(String(cString: strerror(code))). Unplug the phone and plug it back in, or restart the Mac.")
            case .stillRunning:
                return String(localized: "macOS’s Image Capture service didn’t stop. Unplug the phone and plug it back in, or restart the Mac.")
            case .stillHoldsPhone:
                return String(localized: "macOS’s Image Capture service stopped, but the phone is still marked as in use. Unplug the phone and plug it back in.")
            }
        }
    }

    public static let agentName = DeviceHolder.imageCaptureAgentName
    public static let agentPath = "/usr/libexec/ptpcamerad"

    /// The process `pid`, or nil when there is none (or only its zombie).
    public var lookup: @Sendable (Int32) -> ProcessRecord?
    public var currentUserID: @Sendable () -> UInt32
    public var userName: @Sendable (UInt32) -> String?
    /// Sends `signal` to `pid`; 0 on success, else errno.
    public var sendSignal: @Sendable (_ pid: Int32, _ signal: Int32) -> Int32
    /// Whether any USB device or interface still names `pid` as `UsbExclusiveOwner`.
    public var holdsUSB: @Sendable (Int32) -> Bool
    public var sleep: @Sendable (TimeInterval) -> Void
    /// How long SIGTERM is given, then SIGKILL, then the registry to clear.
    public var terminateGrace: TimeInterval = 0.8
    public var killGrace: TimeInterval = 1.0
    public var registryGrace: TimeInterval = 1.0
    public var pollInterval: TimeInterval = 0.05

    public init(
        lookup: @escaping @Sendable (Int32) -> ProcessRecord?,
        currentUserID: @escaping @Sendable () -> UInt32,
        userName: @escaping @Sendable (UInt32) -> String? = { _ in nil },
        sendSignal: @escaping @Sendable (Int32, Int32) -> Int32,
        holdsUSB: @escaping @Sendable (Int32) -> Bool,
        sleep: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.lookup = lookup
        self.currentUserID = currentUserID
        self.userName = userName
        self.sendSignal = sendSignal
        self.holdsUSB = holdsUSB
        self.sleep = sleep
    }

    /// Whether `record` is the Image Capture agent.
    static func isAgent(_ record: ProcessRecord) -> Bool {
        record.name == agentName && (record.path == nil || record.path == agentPath)
    }

    /// Stops the agent running as `pid`. Blocks for up to a few seconds; call
    /// it off the main actor.
    public func release(pid: Int32) -> Outcome {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else {
            return .notImageCaptureAgent(name: "pid \(pid)")
        }
        // Checked before every signal: the pid must still be this user's
        // ptpcamerad.
        func verify() -> Outcome? {
            guard let record = lookup(pid) else { return .alreadyGone }
            guard Self.isAgent(record) else { return .notImageCaptureAgent(name: record.name) }
            let me = currentUserID()
            guard record.realUserID == me, record.effectiveUserID == me else {
                return .ownedByAnotherUser(userName: userName(record.effectiveUserID))
            }
            return nil
        }

        if let refusal = verify() { return refusal == .alreadyGone ? confirmReleased(pid, success: .alreadyGone) : refusal }
        var forced = false
        let termResult = sendSignal(pid, SIGTERM)
        if termResult != 0, termResult != ESRCH { return .signalFailed(errno: termResult) }
        if !waitForExit(pid, within: terminateGrace) {
            switch verify() {
            case .alreadyGone?:
                break
            case let refusal?:
                return refusal
            case nil:
                forced = true
                let killResult = sendSignal(pid, SIGKILL)
                if killResult != 0, killResult != ESRCH { return .signalFailed(errno: killResult) }
                if !waitForExit(pid, within: killGrace) { return .stillRunning }
            }
        }
        return confirmReleased(pid, success: .released(forced: forced))
    }

    private func confirmReleased(_ pid: Int32, success: Outcome) -> Outcome {
        // The kernel drops the process's USB opens as it exits; give the
        // registry a moment to reflect it.
        var waited: TimeInterval = 0
        while holdsUSB(pid) {
            guard waited < registryGrace else { return .stillHoldsPhone }
            sleep(pollInterval)
            waited += pollInterval
        }
        return success
    }

    private func waitForExit(_ pid: Int32, within grace: TimeInterval) -> Bool {
        var waited: TimeInterval = 0
        while lookup(pid) != nil {
            guard waited < grace else { return false }
            sleep(pollInterval)
            waited += pollInterval
        }
        return true
    }
}

public extension ImageCaptureAgentRelease {
    /// The real system: sysctl and proc_pidpath for the process, kill(2) for
    /// the signal, the I/O Registry for the USB check. Elsewhere than macOS
    /// it finds no process, so it never signals anything.
    static var live: ImageCaptureAgentRelease {
        #if os(macOS)
        ImageCaptureAgentRelease(
            lookup: liveLookup,
            currentUserID: { getuid() },
            userName: { uid in
                guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
                return String(cString: name)
            },
            sendSignal: { pid, signal in kill(pid, signal) == 0 ? 0 : errno },
            holdsUSB: { USBDeviceDiscovery.isClaimed(byProcess: $0) },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
        #else
        ImageCaptureAgentRelease(
            lookup: { _ in nil },
            currentUserID: { 0 },
            sendSignal: { _, _ in ESRCH },
            holdsUSB: { _ in false },
            sleep: { _ in }
        )
        #endif
    }
}

#if os(macOS)
private func liveLookup(_ pid: Int32) -> ImageCaptureAgentRelease.ProcessRecord? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    // A zombie has let go of everything; it only waits for launchd to reap it.
    guard info.kp_proc.p_stat != SZOMB else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    let path = length > 0
        ? String(decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        : nil
    return ImageCaptureAgentRelease.ProcessRecord(
        name: name,
        path: path,
        realUserID: info.kp_eproc.e_pcred.p_ruid,
        effectiveUserID: info.kp_eproc.e_ucred.cr_uid
    )
}
#endif
