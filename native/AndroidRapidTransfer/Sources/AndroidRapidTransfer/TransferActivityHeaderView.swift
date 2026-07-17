import AndroidRapidTransferCore
import SwiftUI

/// The transfer panel's always-visible summary line. While work is in flight
/// it shows an overall ring, "Copying 3 of 12 files", bytes, speed and time
/// left, all rolling to their new values; when everything settles it reports
/// how the session went, with a small celebration for a clean finish.
struct TransferActivityHeaderView: View {
    let rows: [TransferPanelRow]
    let overall: TransferOverallProgress?
    let summary: TransferSessionSummary?
    let isExpanded: Bool
    let toggle: () -> Void
    let stopAll: () -> Void
    let clearSettled: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    leadingGauge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            // Counts roll while copying; a new sentence cross-fades.
                            .contentTransition(overall != nil ? .numericText() : .opacity)
                        if let subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .contentTransition(.numericText())
                        }
                    }
                    .motion(Motion.snappy, value: title)
                    .motion(Motion.snappy, value: subtitle)
                    Spacer(minLength: 8)
                    if let percent = overall?.percent {
                        Text(percent, format: .percent.precision(.fractionLength(0)))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: percent))
                            .motion(Motion.snappy, value: percent)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isExpanded ? "Collapse copies" : "Expand copies")
            .accessibilityValue(accessibilityValue)

            if let overall, overall.isCancellable {
                Button("Stop All", action: stopAll)
                    .controlSize(.small)
                    .help("Stop every copy now. Files already copied stay where they are.")
                    .motionTransition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if overall == nil, rows.contains(where: { $0.state.isTerminal }) {
                Button("Clear", action: clearSettled)
                    .controlSize(.small)
                    .help("Remove finished copies from the list")
                    .motionTransition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Text("\(rows.count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
                .contentTransition(.numericText(value: Double(rows.count)))
                .motion(Motion.bouncy, value: rows.count)
                .accessibilityLabel(rows.count == 1 ? "1 copy" : "\(rows.count) copies")

            Button(action: toggle) {
                Image(systemName: "chevron.up")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .motion(Motion.snappy, value: isExpanded)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the list of copies" : "Show the list of copies")
            // The summary button beside it does the same for VoiceOver.
            .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .motion(Motion.snappy, value: overall == nil)
    }

    // MARK: - Gauge

    @ViewBuilder
    private var leadingGauge: some View {
        ZStack {
            if let overall {
                TransferProgressRing(value: overall.percent, systemImage: directionSymbol)
                    .motionTransition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                settledSymbol
                    .motionTransition(.scale(scale: 0.6).combined(with: .opacity))
            }
            TransferCelebrationBurst(trigger: celebrationTrigger)
        }
        .frame(width: 30, height: 30)
        .motion(Motion.bouncy, value: overall == nil)
    }

    private var settledSymbol: some View {
        Image(systemName: settledSymbolName)
            .font(.system(size: 24))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(settledTint)
            .motionBounce(value: summary?.id)
            .accessibilityHidden(true)
    }

    /// Only a clean finish earns confetti; a partial one just settles.
    private var celebrationTrigger: UUID? {
        guard let summary, summary.isCleanSuccess else { return nil }
        return summary.id
    }

    private var directionSymbol: String {
        let directions = Set(rows.filter { !$0.state.isTerminal }.map(\.request.direction))
        switch directions.first {
        case .download where directions.count == 1: return "arrow.down"
        case .upload where directions.count == 1: return "arrow.up"
        default: return "arrow.up.arrow.down"
        }
    }

    private var hasFailures: Bool {
        rows.contains { row in
            if case .failed = row.state { return true }
            return !row.fileFailures.isEmpty
        }
    }

    private var settledSymbolName: String {
        if hasFailures { return "exclamationmark.triangle.fill" }
        if let summary, !summary.isCleanSuccess, summary.jobsCancelled > 0 { return "stop.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var settledTint: Color {
        if hasFailures { return .orange }
        if let summary, !summary.isCleanSuccess, summary.jobsCancelled > 0 { return .secondary }
        return .green
    }

    // MARK: - Copy

    private var title: String {
        if let overall {
            if overall.totalFiles > 1 {
                return "Copying \(overall.filesCompleted.formatted()) of \(overall.totalFiles.formatted()) files"
            }
            if let currentRow {
                return "Copying \(currentRow.sourceSummary)"
            }
            return "Copying…"
        }
        if let summary {
            return summary.headline
        }
        if hasFailures {
            return "Some copies need attention"
        }
        return rows.count == 1 ? "Copy complete" : "Copies complete"
    }

    private var subtitle: String? {
        if let overall {
            var parts: [String] = []
            if overall.totalBytes > 0 {
                parts.append(
                    "\(overall.sentBytes.formatted(.byteCount(style: .file))) of \(overall.totalBytes.formatted(.byteCount(style: .file)))"
                )
            }
            if overall.speed > 0 {
                parts.append(TransferRemainingTime.speedText(megabytesPerSecond: overall.speed))
            }
            if let remaining = TransferRemainingTime.phrase(overall.eta) {
                parts.append(remaining)
            } else if overall.queuedJobCount > 0, parts.isEmpty {
                parts.append("\(overall.queuedJobCount) waiting")
            }
            return parts.isEmpty ? "Preparing…" : parts.joined(separator: " · ")
        }
        guard let summary else { return nil }
        var parts: [String] = []
        if summary.bytesCopied > 0 {
            parts.append(summary.bytesCopied.formatted(.byteCount(style: .file)))
        }
        if let destination = summary.destinationPhrase, summary.filesCopied > 0 {
            parts.append(destination)
        }
        if summary.itemsFailed > 0 {
            return (parts.isEmpty ? "" : parts.joined(separator: " ") + " · ")
                + (isExpanded ? "Review the items below" : "Open the list to review")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var accessibilityValue: String {
        var parts = [title]
        if let percent = overall?.percent {
            parts.append("\(Int((percent * 100).rounded())) percent")
        }
        if let subtitle { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }

    private var currentRow: TransferPanelRow? {
        rows.first { !$0.state.isTerminal }
    }
}
