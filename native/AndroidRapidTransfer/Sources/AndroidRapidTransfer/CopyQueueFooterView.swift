import AndroidRapidTransferCore
import SwiftUI

struct CopyQueueFooterView: View {
    let queue: CopyQueue
    let canExecute: Bool
    let isExecuting: Bool
    let clear: () -> Void
    let execute: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(queue.count == 1 ? "1 item" : "\(queue.count) items")
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(queue.count)))
            Text(
                queue.totalBytes.formatted(.byteCount(style: .file))
                    + (queue.hasUnknownSizes ? "+" : "")
            )
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(queue.totalBytes)))
            Spacer()
            Button("Clear", action: clear)
                .disabled(queue.isEmpty || isExecuting)
            Button(action: execute) {
                HStack(spacing: 6) {
                    if isExecuting {
                        ProgressView()
                            .controlSize(.small)
                            .motionTransition(.scale.combined(with: .opacity))
                    }
                    Text("Copy to Mac…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExecute || isExecuting)
            .help(executeHelp)
        }
        .motion(Motion.snappy, value: queue.count)
        .motion(Motion.snappy, value: isExecuting)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var executeHelp: String {
        if canExecute {
            return "Choose a folder on this Mac and copy these items there, keeping their phone folders."
        }
        if queue.source == .local {
            return "These items came from this Mac. Paste them into the phone pane (⌘V)."
        }
        return "Connect the phone the items came from and add at least one item."
    }
}
