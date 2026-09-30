import MTPKit

enum ConnectionFatalDisposition: Equatable, Sendable {
    case deviceUnavailable
    case requiresReplug
}

enum ConnectionFatalClassifier {
    /// The marker the provider puts in the message when the device has gone
    /// (libusb's name for it, kept as the convention). It is reported inside
    /// whatever operation was running — a listing, a transfer, a storage
    /// query — so the error type alone does not reveal the disconnect.
    static let deviceGoneMarker = "LIBUSB_ERROR_NO_DEVICE"

    static func disposition(for error: any Error) -> ConnectionFatalDisposition? {
        guard let callError = error as? MTPCallError else { return nil }
        switch callError.type {
        case .deviceChanged, .mtpDetectFailed:
            return .deviceUnavailable
        case .deviceSetup:
            return .requiresReplug
        default:
            // A phone that drops off mid-operation surfaces as that
            // operation's failure; treating it as ordinary would leave the
            // app talking to a session the provider has already closed.
            return callError.message.contains(deviceGoneMarker) ? .deviceUnavailable : nil
        }
    }

    /// Whether the controller should reconnect on its own rather than wait for
    /// hotplug or a manual Retry: the provider reported that the device changed,
    /// or that it vanished in the middle of an operation. Both usually mean the
    /// phone re-enumerated — an Android USB-mode switch, a USB reset — not that
    /// the user unplugged it, which hotplug reports
    /// separately. "No MTP device found" alone does not qualify.
    static func triggersReconnect(_ error: any Error) -> Bool {
        guard let callError = error as? MTPCallError else { return false }
        return callError.type == .deviceChanged
            || callError.message.contains(deviceGoneMarker)
    }
}
