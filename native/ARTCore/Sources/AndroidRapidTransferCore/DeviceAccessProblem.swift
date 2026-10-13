import Foundation
import MTPKit

/// Why a phone that is plugged in and in File transfer mode still cannot be
/// opened, when the reason is on the computer's side rather than the phone's:
/// another program has claimed it, or the operating system does not let this
/// user open its USB device node. Neither is fixed by replugging the phone,
/// so the device pane explains them instead of asking for a replug.
///
/// Recognised from the transport's error text, which names the failure kind
/// (`exclusiveAccess`, `notPermitted`) and the device node.
public enum DeviceAccessProblem: Equatable, Sendable {
    /// Another program holds the phone's MTP interface (EBUSY).
    case busy(detail: String)
    /// The USB device node cannot be opened by this user (EACCES/EPERM).
    case permissionDenied(detail: String)

    public init?(message: String) {
        if message.contains("(exclusiveAccess") {
            self = .busy(detail: message)
        } else if message.contains("(notPermitted") {
            self = .permissionDenied(detail: message)
        } else {
            return nil
        }
    }

    public init?(error: any Error) {
        self.init(message: ErrorDescription.message(for: error))
    }

    public var detail: String {
        switch self {
        case let .busy(detail), let .permissionDenied(detail): detail
        }
    }

    /// Who has the phone, when the transport could tell: the single holder in
    /// "… : <holder> is using the phone (exclusiveAccess …)". macOS writes
    /// `ptpcamerad (pid 19641)` (a process, from the I/O Registry's
    /// `UsbExclusiveOwner`) or `AppleUSBACMControl (kernel driver)`; Linux
    /// writes `gvfsd-mtp (pid 42)` or `GNOME Files (gvfsd-mtp), pid 42`.
    /// Nil for a permission problem, an unnamed holder, or several holders.
    public var holder: DeviceHolder? {
        guard case let .busy(detail) = self,
              let marker = detail.range(of: " is using the phone") else { return nil }
        let before = detail[..<marker.lowerBound]
        let start = before.range(of: ": ", options: .backwards)?.upperBound ?? before.startIndex
        return DeviceHolder(text: String(before[start...]))
    }

    /// The USB device node the failure names (`/dev/bus/usb/BBB/DDD`), if any.
    public var deviceNodePath: String? {
        let text = detail
        guard let start = text.range(of: "/dev/bus/usb/") else { return nil }
        let path = text[start.lowerBound...].prefix { $0 == "/" || $0.isLetter || $0.isNumber }
        return path.count > "/dev/bus/usb/".count ? String(path) : nil
    }
}

/// The program or driver that has the phone's MTP interface, as named in a
/// busy error (see ``DeviceAccessProblem/holder``).
public struct DeviceHolder: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case process(pid: Int32)
        case kernelDriver
        /// Named, but neither a pid nor a driver was given.
        case unnamedKind
    }

    /// The process or driver name, for example "ptpcamerad" or "AppleUSBACMControl".
    public let name: String
    public let kind: Kind

    /// macOS's Image Capture agent: a per-user launchd agent
    /// (`/System/Library/LaunchAgents/com.apple.ptpcamerad.plist`, run on
    /// demand through its Mach service, not kept alive) that opens phones
    /// offering a still-image (PTP) interface, which Samsung's MTP interface
    /// is, as soon as they are plugged in.
    public static let imageCaptureAgentName = "ptpcamerad"

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    init?(text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix(" (kernel driver)") {
            self.init(name: String(text.dropLast(" (kernel driver)".count)), kind: .kernelDriver)
        } else if text.hasSuffix(")"), let open = text.range(of: " (pid ", options: .backwards),
                  let pid = Int32(text[open.upperBound...].dropLast()) {
            self.init(name: String(text[..<open.lowerBound]), kind: .process(pid: pid))
        } else if let comma = text.range(of: ", pid ", options: .backwards),
                  let pid = Int32(text[comma.upperBound...]) {
            self.init(name: String(text[..<comma.lowerBound]), kind: .process(pid: pid))
        } else {
            self.init(name: text, kind: .unnamedKind)
        }
    }

    public var processID: Int32? {
        if case let .process(pid) = kind { return pid }
        return nil
    }

    /// Whether this is macOS's Image Capture agent, which the app may offer
    /// to stop (``ImageCaptureAgentRelease``).
    public var isImageCaptureAgent: Bool {
        name == Self.imageCaptureAgentName && processID != nil
    }

    /// Whether the holder is this app itself (a session that has not closed yet).
    public var isCurrentProcess: Bool {
        processID == ProcessInfo.processInfo.processIdentifier
    }
}
