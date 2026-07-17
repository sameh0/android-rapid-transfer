import AppKit
import AndroidRapidTransferCore
import SwiftUI

struct BugReportView: View {
    let connectionController: DeviceConnectionController
    let transferModel: TransferViewModel
    let settings: AppSettings

    private enum Phase: Equatable {
        case idle
        case running(BugReportStage)
        case finished(URL)
        case failed(String, at: BugReportStage?)

        var isRunning: Bool {
            if case .running = self { true } else { false }
        }
    }

    @State private var phase: Phase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SecondaryWindowHeader(
                title: "Report a Bug",
                subtitle: "\(AppIdentity.name) can gather diagnostics into a zip file on your Desktop for you to attach to a bug report.",
                systemImage: "ladybug.fill"
            )

            if phase == .idle {
                GroupBox("Before you start") {
                    VStack(alignment: .leading, spacing: 6) {
                        step(1, "Unlock your phone and connect it to this Mac with a USB cable.")
                        step(2, "On the phone, choose \u{201C}File transfer\u{201D} for the USB connection.")
                        step(
                            3,
                            "Click Create Report. \(AppIdentity.name) disconnects the phone for up to a minute while a USB diagnostic runs, then reconnects it."
                        )
                        step(4, "Attach the zip from your Desktop to the GitHub issue that opens.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .motionTransition(.opacity.combined(with: .move(edge: .top)))
            } else {
                BugReportProgressView(stages: stageStates)
                    .motionTransition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }

            GroupBox("What the report contains") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(BugReportGenerator.contents(), id: \.fileName) { item in
                        Label {
                            Text(item.description)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(
                        "Nothing is sent automatically. The zip stays on your Mac until you choose to attach it, and you can open it to check its contents first."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            status

            HStack {
                Button("Open GitHub Issues") {
                    NSWorkspace.shared.open(BugReportLinks.issuesURL)
                }
                Spacer()
                if case let .finished(url) = phase {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .motionTransition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Button(createButtonTitle, action: createReport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase.isRunning || transferModel.hasActiveTransfers)
            }
        }
        .padding(20)
        .frame(width: 540)
        .motion(Motion.gentle, value: phase)
    }

    private var createButtonTitle: String {
        switch phase {
        case .idle: String(localized: "Create Report")
        case .running: String(localized: "Creating…")
        case .finished, .failed: String(localized: "Create Again")
        }
    }

    private var stageStates: [BugReportProgressView.StageState] {
        switch phase {
        case .idle:
            BugReportProgressView.StageState.all(current: nil)
        case let .running(stage):
            BugReportProgressView.StageState.all(current: stage)
        case .finished:
            BugReportProgressView.StageState.all(current: nil, isFinished: true)
        case let .failed(_, stage):
            BugReportProgressView.StageState.all(current: stage, didFail: true)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            if transferModel.hasActiveTransfers {
                Label(
                    "Finish or stop the copies in progress first. Creating a report briefly disconnects the phone.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .running:
            Text("The phone will reconnect when this finishes.")
                .foregroundStyle(.secondary)
        case let .finished(url):
            Label("Saved \(url.lastPathComponent) to your Desktop.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .motionBounce(value: url)
                .motionTransition(.opacity.combined(with: .move(edge: .bottom)))
        case let .failed(message, _):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func createReport() {
        guard !phase.isRunning else { return }
        withMotion(Motion.gentle) { phase = .running(.release) }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
        let generator = BugReportGenerator(
            session: ConnectionControllerBugReportSession(
                controller: connectionController,
                hasActiveTransfers: { [transferModel] in transferModel.hasActiveTransfers },
                hotplugEnabled: { [settings] in settings.enableUsbHotplug }
            ),
            debugTool: SwiftMTPDiagnosticTool(),
            diagnostics: .live(settings: settings, batchStore: TransferBatchStore()),
            outputDirectory: desktop
        )
        Task {
            var currentStage: BugReportStage?
            do {
                let url = try await generator.generate { stage in
                    currentStage = stage
                    withMotion(Motion.snappy) { phase = .running(stage) }
                }
                withMotion(Motion.celebrate) { phase = .finished(url) }
                AccessibilityNotification.Announcement("Bug report saved to your Desktop").post()
                NSWorkspace.shared.activateFileViewerSelecting([url])
                NSWorkspace.shared.open(
                    BugReportLinks.newIssueURL(
                        appVersion: AppVersion.current,
                        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
                    )
                )
            } catch {
                withMotion(Motion.gentle) {
                    phase = .failed(error.localizedDescription, at: currentStage)
                }
                AccessibilityNotification.Announcement("The bug report couldn’t be created").post()
            }
        }
    }
}

/// The report's stages as a checklist: each one spins while it runs and ticks
/// itself off when done.
struct BugReportProgressView: View {
    struct StageState: Equatable, Identifiable {
        enum State: Equatable {
            case pending, active, done, failed
        }

        let stage: BugReportStage
        let state: State
        var id: BugReportStage { stage }

        /// Every stage's state while `current` runs (or failed): earlier
        /// stages are done, later ones pending. No current stage means
        /// nothing has started, unless the whole report is finished.
        static func all(current: BugReportStage?, isFinished: Bool = false, didFail: Bool = false) -> [Self] {
            BugReportStage.allCases.map { stage in
                let state: State
                if isFinished {
                    state = .done
                } else if let current, stage < current {
                    state = .done
                } else if stage == current {
                    state = didFail ? .failed : .active
                } else {
                    state = .pending
                }
                return Self(stage: stage, state: state)
            }
        }
    }

    let stages: [StageState]

    private var fractionDone: Double {
        guard !stages.isEmpty else { return 0 }
        return Double(stages.count { $0.state == .done }) / Double(stages.count)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: fractionDone)
                    .progressViewStyle(.linear)
                    .tint(stages.contains { $0.state == .failed } ? .red : .accentColor)
                    .accessibilityLabel(Text("Report progress"))
                ForEach(stages) { item in
                    BugReportStageRow(item: item)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Progress")
        }
        .motion(Motion.snappy, value: stages)
    }
}

private struct BugReportStageRow: View {
    let item: BugReportProgressView.StageState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if item.state == .active {
                    ProgressView()
                        .controlSize(.small)
                        .motionTransition(.opacity)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                        .motionBounce(value: item.state == .done)
                        .motionTransition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 20, height: 20)
            Text(item.stage.title)
                .foregroundStyle(item.state == .pending ? .secondary : .primary)
                .fontWeight(item.state == .active ? .semibold : .regular)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(stateDescription))
    }

    private var symbol: String {
        switch item.state {
        case .pending, .active: item.stage.systemImage
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var tint: AnyShapeStyle {
        switch item.state {
        case .pending, .active: AnyShapeStyle(.tertiary)
        case .done: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.red)
        }
    }

    private var stateDescription: String {
        switch item.state {
        case .pending: String(localized: "Waiting")
        case .active: String(localized: "In progress")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        }
    }
}
