import AndroidRapidTransferCore
import AppKit
import UserNotifications

/// `UNUserNotificationCenter` behind ``UserNotificationPosting``.
struct SystemNotificationCenter: UserNotificationPosting {
    /// The real center, or nil when the process is not an app bundle
    /// (`swift run`): the notification center traps without one.
    static func makeIfAvailable() -> SystemNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else { return nil }
        return SystemNotificationCenter()
    }

    func authorization() async -> UserNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ notification: TransferCompletionNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
