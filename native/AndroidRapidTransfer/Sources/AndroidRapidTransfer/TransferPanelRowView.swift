import AndroidRapidTransferCore
import AppKit
import SwiftUI

/// One job in the transfer panel. The active row fills its bar with a spring
/// and a sheen while bytes flow; a finished row draws its check; a failed row
/// shakes once, explains itself in plain words, and offers Retry with the
/// technical detail one click away.
struct TransferPanelRowView: View {
    let row: TransferPanelRow
    let cancel: () -> Void
    let dismiss: () -> Void
    /// `nil` when this row cannot be retried right now.
    let retry: (() -> Void)?

    @State private var showsDetails = false
    /// Bumped each time the row fails, to shake it once.
    @State private var failureShakes = 0

    /// Rows that settled this long ago appear settled, without replaying
    /// their check or shake when they scroll back into view.
    private static let freshSettlementWindow: TimeInterval = 1.5

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            itemIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.sourceSummary)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(directionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(routeHelp)
                stateContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rowActions
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .background(rowTint)
        .motionShake(trigger: failureShakes)
        // Only on failing: a retried row leaves the failed state quietly.
        .onChange(of: isFailed) { _, failed in
            if failed { failureShakes += 1 }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Icon

    private var itemIcon: some View {
        Image(nsImage: TransferItemIcon.image(for: row.request, name: row.sourceSummary))
        .resizable()
        .interpolation(.high)
        .frame(width: 28, height: 28)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: row.request.direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, directionTint)
                .background(Circle().fill(.background).padding(1))
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }

    private var directionLabel: String {
        row.request.direction == .download ? "to Mac" : "to phone"
    }

    /// "From /DCIM/Camera on the phone to /Users/me/Pictures on this Mac".
    private var routeHelp: String {
        let from = row.sourceDirectory ?? "/"
        let destination = row.localResultPaths.count == 1 && row.request.completionAction != nil
            ? URL(fileURLWithPath: row.localResultPaths[0]).deletingLastPathComponent().path
            : row.request.destination
        return row.request.direction == .download
            ? "From \(from) on the phone to \(destination) on this Mac"
            : "From \(from) on this Mac to \(destination) on the phone"
    }

    private var directionTint: Color {
        row.request.direction == .download ? .accentColor : .teal
    }

    // MARK: - State

    @ViewBuilder
    private var stateContent: some View {
        switch row.state {
        case .queued:
            Label("Waiting…", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .preprocessing:
            VStack(alignment: .leading, spacing: 4) {
                TransferProgressBar(value: nil, isFlowing: true, tint: directionTint, height: 5)
                    .accessibilityLabel("Preparing \(row.sourceSummary)")
                Text(row.cancelRequested ? "Stopping…" : "Preparing…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case let .transferring(progress):
            transferring(progress)
        case .completed:
            completed
        case let .failed(failure):
            failed(failure)
        case .cancelled:
            HStack(spacing: 6) {
                Image(systemName: "stop.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(cancelledSummary)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
    }

    private func transferring(_ progress: TransferProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TransferProgressBar(
                value: progress.fraction,
                isFlowing: progress.speed > 0 && !row.cancelRequested,
                tint: row.cancelRequested ? .secondary : directionTint,
                height: 5
            )
            .accessibilityLabel("Copying \(row.sourceSummary)")

            HStack(spacing: 6) {
                Text(row.cancelRequested ? "Stopping…" : progress.currentFileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.cancelRequested ? Color.orange : Color.secondary)
                Spacer(minLength: 8)
                Group {
                    if progress.totalFiles > 1 {
                        Text("\(progress.filesSent) of \(progress.totalFiles)")
                            .contentTransition(.numericText(value: Double(progress.filesSent)))
                    }
                    if progress.totalBytes > 0 {
                        Text("\(byteText(progress.sentBytes)) of \(byteText(progress.totalBytes))")
                            .contentTransition(.numericText(value: Double(progress.sentBytes)))
                    }
                    if progress.speed > 0 {
                        Text(TransferRemainingTime.speedText(megabytesPerSecond: progress.speed))
                            .contentTransition(.numericText(value: progress.speed))
                    }
                    if let remaining = TransferRemainingTime.phrase(progress.eta) {
                        Text(remaining)
                            .contentTransition(.numericText())
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .motion(Motion.snappy, value: progress.sentBytes)
        }
    }

    private var completed: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TransferCheckmark(diameter: 14, animated: settledRecently)
                Text(completionTitle)
                    .font(.footnote)
                if let completionSummary {
                    Text(completionSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !row.fileFailures.isEmpty {
                fileFailureList
            }
        }
    }

    private func failed(_ failure: TransferFailureDescription) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: failure.symbolName)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(failure.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .accessibilityElement(children: .combine)
            Text(failure.guidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failureSummary {
                Text(failureSummary)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            if !row.fileFailures.isEmpty {
                fileFailureList
            }
            detailsDisclosure(technical: failure.technicalDetail)
        }
    }

    /// Per-file failures of a job that otherwise kept going: a count line and
    /// the friendly reason for each file behind the details disclosure.
    private var fileFailureList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(fileFailureSummary, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
            if case .completed = row.state {
                detailsDisclosure(technical: nil)
            }
        }
    }

    private func detailsDisclosure(technical: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withMotion(Motion.snappy) { showsDetails.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    Text(showsDetails ? "Hide Details" : "Details")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsDetails ? "Hide technical details" : "Show technical details")

            if showsDetails {
                let text = detailText(technical: technical)
                HStack(alignment: .top, spacing: 6) {
                    Text(text)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy Details", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the technical details, for a bug report")
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Radius.small, style: .continuous))
                .motionTransition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var rowActions: some View {
        HStack(spacing: 2) {
            switch row.state {
            case .queued:
                iconButton("Cancel", systemImage: "xmark.circle.fill", help: "Remove from the queue", action: cancel)
            case .preprocessing, .transferring:
                if row.cancelRequested {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Stopping")
                } else {
                    iconButton("Stop", systemImage: "stop.circle.fill", help: "Stop now. Files already copied stay.", action: cancel)
                }
            case .completed, .failed, .cancelled:
                if let retry {
                    iconButton("Retry", systemImage: "arrow.clockwise.circle.fill", help: retryHelp, action: retry)
                        .foregroundStyle(Color.accentColor)
                }
                if case .completed = row.state, !row.localResultPaths.isEmpty {
                    iconButton("Show in Finder", systemImage: "magnifyingglass.circle.fill", help: "Show in Finder", action: revealInFinder)
                }
                iconButton("Dismiss", systemImage: "xmark.circle.fill", help: "Remove from the list", action: dismiss)
            }
        }
        .font(.title3)
        .foregroundStyle(.secondary)
    }

    private func iconButton(
        _ title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel("\(title) \(row.sourceSummary)")
    }

    private var retryHelp: String {
        row.fileFailures.isEmpty ? "Try this copy again" : "Copy the files that failed again"
    }

    private func revealInFinder() {
        let fileManager = FileManager.default
        let existing = row.localResultPaths
            .filter { fileManager.fileExists(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
        if existing.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: row.request.destination))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    // MARK: - Copy

    private var isFailed: Bool {
        if case .failed = row.state { return true }
        return false
    }

    private var settledRecently: Bool {
        guard let endedAt = row.endedAt else { return false }
        return Date.now.timeIntervalSince(endedAt) < Self.freshSettlementWindow
    }

    private var rowTint: Color {
        isFailed ? Color.red.opacity(0.06) : .clear
    }

    private var completionTitle: String {
        row.fileFailures.isEmpty ? "Copied" : "Copied with problems"
    }

    private var cancelledSummary: String {
        guard let progress = row.lastProgress, progress.filesSent > 0 else { return "Stopped" }
        return "Stopped · \(progress.filesSent) of \(progress.totalFiles) files copied"
    }

    /// "2 files failed" for jobs that finished while skipping failed files.
    private var fileFailureSummary: String {
        let count = row.fileFailures.count
        return count == 1 ? "1 file failed" : "\(count) files failed"
    }

    /// The disclosure's text: the job's technical detail and, for each file
    /// that failed, its name, friendly reason and raw message.
    private func detailText(technical: String?) -> String {
        var lines: [String] = []
        if let technical { lines.append(technical) }
        for (failure, description) in zip(row.fileFailures, row.fileFailureDescriptions) {
            let name = URL(fileURLWithPath: failure.source).lastPathComponent
            lines.append("\(name) — \(description.title): \(failure.message)")
        }
        return lines.joined(separator: "\n")
    }

    /// e.g. "50 MB in 1 min 2 sec", falling back to whichever part is known.
    private var completionSummary: String? {
        switch (row.totalBytes, row.duration) {
        case let (totalBytes?, duration?):
            return "\(byteText(totalBytes)) in \(durationText(duration))"
        case let (totalBytes?, nil):
            return byteText(totalBytes)
        case let (nil, duration?):
            return "in \(durationText(duration))"
        case (nil, nil):
            return nil
        }
    }

    /// e.g. "24 MB of 50 MB copied before it stopped".
    private var failureSummary: String? {
        guard let sentBytes = row.sentBytes, sentBytes > 0 else { return nil }
        if let totalBytes = row.totalBytes, totalBytes > 0 {
            return "\(byteText(sentBytes)) of \(byteText(totalBytes)) copied before it stopped"
        }
        return "\(byteText(sentBytes)) copied before it stopped"
    }

    private func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private func durationText(_ interval: TimeInterval) -> String {
        guard interval >= 1 else { return "under a second" }
        return Duration.seconds(interval).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
    }
}
