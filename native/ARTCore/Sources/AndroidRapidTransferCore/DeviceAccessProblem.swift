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

    /// The USB device node the failure names (`/dev/bus/usb/BBB/DDD`), if any.
    public var deviceNodePath: String? {
        let text = detail
        guard let start = text.range(of: "/dev/bus/usb/") else { return nil }
        let path = text[start.lowerBound...].prefix { $0 == "/" || $0.isLetter || $0.isNumber }
        return path.count > "/dev/bus/usb/".count ? String(path) : nil
    }
}
