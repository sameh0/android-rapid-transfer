import AndroidRapidTransferCore
import SwiftUI

/// Connecting to a phone: the first time, or again on its own after the
/// connection dropped. Reconnecting is deliberately calm — it usually fixes
/// itself — and counts its attempts rather than raising an alarm.
struct DetectingDeviceView: View {
    /// Nil while connecting normally; the attempt count while reconnecting.
    var reconnect: ConnectionReconnectProgress?
    /// False under Reduce Motion, while the window is inactive or hidden, and
    /// once the illustration has settled after a long wait.
    @Environment(\.motionAllowsIdleLoops) private var illustrationIsMoving

    var body: some View {
        VStack(spacing: 12) {
            if let reconnect {
                ConnectionMessageView(
                    title: "Reconnecting…",
                    message: "The connection dropped. This usually sorts itself out in a moment — keep your phone unlocked."
                )
                attemptLabel(reconnect)
            } else {
                ConnectionMessageView(
                    title: "Connecting to your phone…",
                    message: "Keep your phone unlocked. If it asks to allow access to phone data, tap Allow."
                )
                // The illustration's signal is the progress cue; when it is
                // still, fall back to the system spinner.
                if !illustrationIsMoving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func attemptLabel(_ progress: ConnectionReconnectProgress) -> some View {
        if progress.attempt > 0 {
            Text("Attempt \(progress.attempt) of \(progress.limit)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(progress.attempt)))
                .motion(Motion.snappy, value: progress.attempt)
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            Text("Waiting for the phone…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
