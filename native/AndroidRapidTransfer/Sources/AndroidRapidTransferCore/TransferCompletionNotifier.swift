import Foundation

/// Whether the user lets the app post notifications.
public enum UserNotificationAuthorization: Equatable, Sendable {
    /// Never asked.
    case notDetermined
    case authorized
    /// Turned off, in the prompt or in System Settings. Never asked again.
    case denied
}

/// The slice of the system notification center the completion notifier
/// needs, so its policy can be tested without posting real notifications.
public protocol UserNotificationPosting: Sendable {
    func authorization() async -> UserNotificationAuthorization
    /// Shows the system prompt; true when the user allowed notifications.
    func requestAuthorization() async -> Bool
    func post(_ notification: TransferCompletionNotification) async
}

/// What a finished copy says in Notification Center.
public struct TransferCompletionNotification: Equatable, Sendable {
    /// Replaces an earlier notification for the same session, never another's.
    public let identifier: String
    public let title: String
    public let body: String

    public init(summary: TransferSessionSummary) {
        identifier = "transfer-session-\(summary.id.uuidString)"
        title = summary.headline
        var details: [String] = []
        if let destination = summary.destinationPhrase, summary.filesCopied > 0 {
            let copied = summary.bytesCopied > 0
                ? summary.bytesCopied.formatted(.byteCount(style: .file)) + " copied " + destination
                : "Copied " + destination
            details.append(copied)
        }
        if summary.itemsFailed > 0 {
            details.append("Open \(AppIdentity.name) to see what needs attention.")
        }
        body = details.isEmpty ? "Your copy has finished." : details.joined(separator: ". ")
    }
}

/// Posts a notification when a copy session finishes while the app is in the
/// background, alongside the Dock bounce. Permission is asked for lazily, the
/// first time there is something to report, never at launch, and a refusal
/// is respected: the notifier then stays silent.
@MainActor
public final class TransferCompletionNotifier {
    private let center: (any UserNotificationPosting)?
    private let isAppActive: @MainActor () -> Bool

    /// `center` is nil where notifications are unavailable (an unbundled
    /// `swift run`); the notifier then does nothing.
    public init(
        center: (any UserNotificationPosting)?,
        isAppActive: @escaping @MainActor () -> Bool
    ) {
        self.center = center
        self.isAppActive = isAppActive
    }

    /// Tells a user who switched away that the session finished. Returns
    /// whether a notification was posted.
    @discardableResult
    public func sessionFinished(_ summary: TransferSessionSummary) async -> Bool {
        // A session the user stopped needs no news.
        guard let center, !isAppActive(), summary.filesCopied > 0 || summary.itemsFailed > 0 else {
            return false
        }
        switch await center.authorization() {
        case .denied:
            return false
        case .authorized:
            break
        case .notDetermined:
            guard await center.requestAuthorization() else { return false }
        }
        await center.post(TransferCompletionNotification(summary: summary))
        return true
    }
}
