import AndroidRapidTransferCore
import SwiftUI

/// The running apps known to block the phone connection, each with a Quit
/// button, at the top of the Troubleshooting window.
struct ConflictingAppsCard: View {
    let model: ConflictingAppsModel
    /// Opens the help topic that explains these apps.
    var showDetails: (() -> Void)?

    private var isClear: Bool { model.entries.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)
            if !isClear {
                Divider()
                    .padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach(model.entries) { entry in
                        ConflictingAppRow(entry: entry, quit: { model.quit(entry) })
                            .motionTransition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .motion(Motion.snappy, value: model.entries)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isClear ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(tint.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let showDetails {
                Button("Learn More", action: showDetails)
                    .buttonStyle(.link)
                    .accessibilityHint(Text("Opens “Apps that block the connection”"))
            }
            if !isClear {
                Button("Quit All") { model.quitAll() }
                    .disabled(!model.canQuitAll)
                    .accessibilityLabel(Text("Quit all apps that block the connection"))
            }
        }
    }

    private var tint: Color { isClear ? .green : .orange }

    private var title: LocalizedStringKey {
        switch model.entries.count {
        case 0: "No conflicting apps are running"
        case 1: "1 app may block the connection"
        default: "\(model.entries.count) apps may block the connection"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch model.entries.count {
        case 0: "Apps known to take the phone’s connection show up here while they run."
        case 1: "Quit it before connecting your phone. It quits as with ⌘Q, so you can save your work."
        default: "Quit them before connecting your phone. Each quits as with ⌘Q, so you can save your work."
        }
    }
}

/// One running app: its icon, name and why it conflicts, and a Quit button
/// that turns into progress, then a retry if the app doesn't quit.
private struct ConflictingAppRow: View {
    let entry: ConflictingAppsModel.Entry
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: WorkspaceRunningApplications.icon(forProcessIdentifier: entry.processIdentifier))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                detail
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var detail: some View {
        switch entry.quitState {
        case .running, .quitting:
            Text(entry.app.reason)
                .foregroundStyle(.secondary)
        case .stillRunning:
            Text("It didn’t quit. It may be asking to save changes: switch to it, then try again.")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch entry.quitState {
        case .running:
            Button("Quit", action: quit)
                .accessibilityLabel(Text("Quit \(entry.name)"))
        case .quitting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Quitting…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Quitting \(entry.name)"))
        case .stillRunning:
            HStack(spacing: 8) {
                Button("Show") {
                    WorkspaceRunningApplications.activate(processIdentifier: entry.processIdentifier)
                }
                .accessibilityLabel(Text("Show \(entry.name)"))
                Button("Try Again", action: quit)
                    .accessibilityLabel(Text("Try quitting \(entry.name) again"))
            }
        }
    }
}
