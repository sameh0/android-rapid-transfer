import MTPKit

enum ConnectionFatalDisposition: Equatable, Sendable {
    case deviceUnavailable
    case requiresReplug
    /// The phone could not be opened for a reason on the computer's side:
    /// another program or driver holds its MTP interface, this user may not
    /// open it (``DeviceAccessProblem``), or (macOS) the claim failed
    /// otherwise (``InterfaceClaimFailure``). A replug is not the cure, so
    /// the controller reports a retryable error that names the cause.
    case accessBlocked
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
            // Claiming the interface is part of setup; when the transport says
            // it was taken or refused, the cause is on this computer.
            if DeviceAccessProblem(message: callError.message) != nil { return .accessBlocked }
            #if os(macOS)
            // Any other failed claim on macOS (kIOReturnInternalError was
            // seen) is explained with its status and offered Retry: a replug
            // demonstrably did not help. Linux keeps the replug screen.
            if InterfaceClaimFailure(message: callError.message) != nil { return .accessBlocked }
            #endif
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
