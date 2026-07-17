import AppKit
import AndroidRapidTransferCore
import SwiftUI

/// Owns the app's session marker: writes it at launch, clears it on a clean
/// quit. Self-contained so it needs no app delegate.
@MainActor
enum SessionMarker {
    private static let monitor = AbnormalExitMonitor()
    private static var terminationObserver: NSObjectProtocol?

    /// Starts the session and reports whether the previous one ended abnormally.
    static func begin() -> AbnormalExitNotice {
        // The mock-device debug mode is not a real session.
        guard !CommandLine.arguments.contains("--mock") else {
            return AbnormalExitNotice(previousSessionEndedAbnormally: false)
        }
        let endedAbnormally = monitor.beginSession()
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    monitor.endSessionCleanly()
                }
            }
        }
        return AbnormalExitNotice(previousSessionEndedAbnormally: endedAbnormally)
    }
}

/// Non-blocking banner shown once after a session that did not quit cleanly.
struct AbnormalExitNoticeView: View {
    let reportBug: () -> Void
    let dismiss: () -> Void
    @State private var hasAppeared = false

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text("\(AppIdentity.name) didn’t quit normally last time. If something went wrong, a bug report helps get it fixed.")
            } icon: {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(.orange)
                    // Once, as the banner lands, to draw the eye without alarm.
                    .motionBounce(value: hasAppeared)
            }
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Report a Bug…", action: reportBug)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(.yellow.opacity(0.12))
        .accessibilityElement(children: .contain)
        .onAppear {
            // Deferred a beat so the bounce plays after the slide-in, not under it.
            DispatchQueue.main.asyncAfter(deadline: .now() + MotionPolicy.current.duration(Motion.Duration.slow)) {
                hasAppeared = true
            }
        }
    }
}

private struct AbnormalExitNoticeModifier: ViewModifier {
    let notice: AbnormalExitNotice
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if notice.isVisible {
                VStack(spacing: 0) {
                    AbnormalExitNoticeView(
                        reportBug: {
                            withMotion(Motion.gentle, notice.dismiss)
                            openWindow(id: AppWindowID.reportBug)
                        },
                        dismiss: { withMotion(Motion.gentle, notice.dismiss) }
                    )
                    Divider()
                }
                .motionTransition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
    }
}

extension View {
    func abnormalExitNotice(_ notice: AbnormalExitNotice) -> some View {
        modifier(AbnormalExitNoticeModifier(notice: notice))
    }
}
