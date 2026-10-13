import Foundation

/// The phone's MTP interface could not be claimed, for a reason other than
/// another program holding it (``DeviceAccessProblem/busy``): the provider's
/// "could not open the MTP interface: …" setup failure, with the OS status
/// the transport reported. On macOS a replug is not the cure the replug
/// screen would promise (seen: kIOReturnInternalError right after macOS's
/// Image Capture agent let go of a Samsung phone), so the app explains it
/// and offers Retry instead.
public struct InterfaceClaimFailure: Equatable, Sendable {
    /// What the provider writes before every claim failure.
    public static let marker = "could not open the MTP interface: "

    public let detail: String
    /// The IOReturn's name, for example "kIOReturnInternalError".
    public let statusName: String?
    /// The status as the transport printed it, for example "0xe00002c9".
    public let statusCode: String?

    public init?(message: String) {
        guard message.contains(Self.marker), !message.contains("(exclusiveAccess") else { return nil }
        detail = message
        statusName = Self.word(after: "kIOReturn", in: message).map { "kIOReturn" + $0 }
        statusCode = Self.word(after: "IOReturn 0x", in: message, backwards: true).map { "0x" + $0 }
    }

    private static func word(after prefix: String, in text: String, backwards: Bool = false) -> String? {
        guard let range = text.range(of: prefix, options: backwards ? .backwards : []) else { return nil }
        let word = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
        return word.isEmpty ? nil : String(word)
    }
}

/// What the device pane says when connecting failed because of something on
/// the Mac (another program holds the phone, or the interface could not be
/// claimed), built from the error the controller reports. Nil for any other
/// failure, which keeps the generic error screen.
public struct ConnectionBlockedPresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    /// What to do next.
    public let guidance: String
    /// Offer "Release the Phone" (stop macOS's Image Capture agent, then retry).
    public let offersRelease: Bool
    /// The full error, for Details.
    public let detail: String
    public let holder: DeviceHolder?

    public init?(message errorMessage: String) {
        let app = AppIdentity.name
        detail = errorMessage
        if case .busy? = DeviceAccessProblem(message: errorMessage) {
            let holder = DeviceAccessProblem(message: errorMessage)?.holder
            self.holder = holder
            switch holder {
            case let holder? where holder.isImageCaptureAgent:
                title = String(localized: "macOS’s Image Capture service is using your phone")
                message = String(localized: "Image Capture’s background service (ptpcamerad) opened the phone for photo import as soon as it was plugged in, so \(app) can’t connect to it. Only one program can use the phone at a time.")
                guidance = String(localized: "Release the Phone stops that service for now and connects right away. macOS starts it again the next time an app needs it.")
                offersRelease = true
            case let holder? where holder.isCurrentProcess:
                title = String(localized: "The previous connection is still closing")
                message = String(localized: "\(app) still has the phone open from an earlier connection.")
                guidance = String(localized: "Wait a moment, then click Retry.")
                offersRelease = false
            case let holder? where holder.kind == .kernelDriver:
                title = String(localized: "A macOS driver is using your phone")
                message = String(localized: "The \(holder.name) driver has claimed the phone’s file transfer connection, so \(app) can’t connect to it.")
                guidance = String(localized: "Click Retry. If it keeps failing, unplug the phone and plug it back in.")
                offersRelease = false
            case let holder?:
                let name = holder.processID.map { String(localized: "“\(holder.name)” (process \($0))") }
                    ?? String(localized: "“\(holder.name)”")
                title = String(localized: "Another program is using your phone")
                message = String(localized: "\(name) has the phone open, so \(app) can’t connect to it. Only one program can use the phone at a time.")
                guidance = String(localized: "Quit \(holder.name), then click Retry.")
                offersRelease = false
            case nil:
                title = String(localized: "Another program is using your phone")
                message = String(localized: "Another program has the phone open, so \(app) can’t connect to it. Only one program can use the phone at a time.")
                guidance = String(localized: "Quit apps that open phones, such as Image Capture, Photos, Android File Transfer or Smart Switch, then click Retry. Troubleshooting lists the ones that are running.")
                offersRelease = false
            }
        } else if let failure = InterfaceClaimFailure(message: errorMessage) {
            holder = nil
            let code = [failure.statusName, failure.statusCode?.uppercased().replacingOccurrences(of: "0X", with: "0x")]
                .compactMap { $0 }
                .joined(separator: ", ")
            title = String(localized: "Couldn’t open the phone’s file transfer connection")
            message = code.isEmpty
                ? String(localized: "macOS didn’t let \(app) open the phone’s file transfer (MTP) connection.")
                : String(localized: "macOS didn’t let \(app) open the phone’s file transfer (MTP) connection (\(code)).")
            guidance = String(localized: "Click Retry. If it keeps failing, quit apps that open phones (Troubleshooting lists them), then unplug the phone and plug it back in.")
            offersRelease = false
        } else {
            return nil
        }
    }
}
