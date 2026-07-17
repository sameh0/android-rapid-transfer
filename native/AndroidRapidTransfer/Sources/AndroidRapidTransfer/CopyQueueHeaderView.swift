import AndroidRapidTransferCore
import SwiftUI

struct CopyQueueHeaderView: View {
    let queue: CopyQueue
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: queue.isEmpty ? "tray" : "tray.full.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                        .motionBounce(value: queue.count)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(queue.count == 1 ? "1 item queued" : "\(queue.count) items queued")
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .contentTransition(.numericText(value: Double(queue.count)))
                        Text(sizeText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(queue.totalBytes)))
                    }
                    .motion(Motion.snappy, value: queue.count)
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isExpanded ? "Collapse copy queue" : "Expand copy queue")
            .accessibilityValue(queue.count == 1 ? "1 item queued, \(sizeText)" : "\(queue.count) items queued, \(sizeText)")

            Button(action: toggle) {
                Image(systemName: "chevron.up")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .motion(Motion.snappy, value: isExpanded)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the copy queue" : "Show the copy queue")
            // The summary button beside it does the same for VoiceOver.
            .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var sizeText: String {
        queue.totalBytes.formatted(.byteCount(style: .file)) + (queue.hasUnknownSizes ? "+" : "")
    }
}
