import AndroidRapidTransferCore
import SwiftUI

/// A strip across the top of a pane. It drops in on a spring when it appears;
/// an error also shakes, again whenever its message changes, so a repeated
/// failure is noticed rather than looking like nothing happened.
struct ErrorBannerView: View {
    enum Tone {
        /// Something the user asked for failed.
        case error
        /// Something happened on its own that the user should know about,
        /// such as the connection dropping.
        case notice
    }

    let message: String
    let tone: Tone
    let actionTitle: String?
    let actionSystemImage: String
    let action: () -> Void
    @State private var hasAppeared = false

    init(error: BrowserPaneError, dismiss: @escaping () -> Void) {
        message = error.message
        tone = .error
        actionTitle = "Dismiss"
        actionSystemImage = "xmark"
        action = dismiss
    }

    init(
        message: String,
        tone: Tone = .error,
        actionTitle: String?,
        actionSystemImage: String,
        action: @escaping () -> Void
    ) {
        self.message = message
        self.tone = tone
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .motionBounce(value: message)
                    .accessibilityHidden(true)
                Text(message)
                    .foregroundStyle(tone == .error ? color : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(tone == .error ? "Error: \(message)" : message)
            }
            .motionShake(trigger: shakeTrigger)
            Spacer(minLength: 8)
            if let actionTitle {
                Button(actionTitle, systemImage: actionSystemImage, action: action)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(color.opacity(tone == .error ? 0.08 : 0.1))
        .offset(y: hasAppeared ? 0 : -8)
        .opacity(hasAppeared ? 1 : 0)
        .motion(Motion.bouncy, value: hasAppeared)
        .onAppear {
            hasAppeared = true
            announce()
        }
        .onChange(of: message) { _, _ in announce() }
        .accessibilityElement(children: .contain)
        .motionTransition(.move(edge: .top).combined(with: .opacity))
    }

    private func announce() {
        AccessibilityNotification.Announcement(tone == .error ? "Error: \(message)" : message).post()
    }

    /// Errors shake as they land and whenever the message changes.
    private var shakeTrigger: [String] {
        tone == .error && hasAppeared ? [message] : []
    }

    private var symbol: String {
        switch tone {
        case .error: "exclamationmark.triangle.fill"
        case .notice: "info.circle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .error: .red
        case .notice: .orange
        }
    }
}
