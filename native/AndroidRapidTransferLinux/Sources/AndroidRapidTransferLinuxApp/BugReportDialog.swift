import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// Help › Report a Bug: lists what the report contains, asks where to save
/// the zip, builds it with Core's ``BugReportGenerator`` (ticking off each
/// stage) and offers the new-issue page.
@MainActor
final class BugReportDialog {
    let dialog = Dialog(title: "Report a Bug", width: 560, height: 680)
    private unowned let app: AppController
    private let stageList = ListBox()
    private var stageRows: [BugReportStage: (icon: Image, spinner: Spinner)] = [:]
    private let createButton = Button("Create Report…", iconName: "document-save-symbolic").css("pill", "suggested-action")
    private let result = Box(.vertical, spacing: 10)
    private let stack = Stack(transition: .crossfade, duration: Motion.Duration.standard)

    init(app: AppController) {
        self.app = app
        build()
    }

    func present(parent: Widget?) {
        OpenDialogs.keep(self, while: dialog)
        dialog.present(parent: parent)
    }

    private func build() {
        let toolbar = ToolbarView()
        toolbar.addTopBar(HeaderBar())
        let page = PreferencesPage(title: "Report a Bug")

        let intro = PreferencesGroup(
            title: "Create a Diagnostic Report",
            description: "\(AppIdentity.name) can gather diagnostics into a zip file for you to attach to a bug report. Nothing is sent anywhere."
        )
        let steps = ListBox()
        for (index, text) in [
            "Keep the phone connected if the problem involves it.",
            "Click Create Report… and choose where to save the zip. The phone is disconnected briefly while its USB diagnostic runs.",
            "Open the issue page on GitHub and describe what happened.",
            "Attach the zip to the issue."
        ].enumerated() {
            let number = Label("\(index + 1)").css("step-number").align(v: .start)
            let label = Label(text).align(h: .start).expand(h: true)
            label.wraps = true
            label.xalign = 0
            steps.append(Box(.horizontal, spacing: 12, [number, label]).css("onboarding-step"))
        }
        intro.add(steps)
        page.add(intro)

        let contents = PreferencesGroup(title: "The Report Contains")
        for item in BugReportGenerator.contents() {
            let row = ActionRow(title: item.fileName, subtitle: item.description)
            row.addPrefix(Image(iconName: "text-x-generic-symbolic"))
            contents.add(row)
        }
        page.add(contents)

        let progress = PreferencesGroup(title: "Progress")
        for stage in BugReportStage.allCases {
            let icon = Image(iconName: "content-loading-symbolic").css("dim-label")
            let spinner = Spinner().sizeRequest(width: 16, height: 16)
            spinner.isVisible = false
            let label = Label(stage.title).align(h: .start).expand(h: true)
            stageList.append(Box(.horizontal, spacing: 12, [icon, spinner, label]).css("stage-row"))
            stageRows[stage] = (icon, spinner)
        }
        progress.add(stageList)
        stack.add(Box(), name: "idle")
        stack.add(progress, name: "progress")
        stack.visibleChildName = "idle"
        let actions = PreferencesGroup(title: "")
        createButton.align(h: .center)
        createButton.onClicked { [weak self] in self?.create() }
        result.align(h: .center)
        actions.add(Box(.vertical, spacing: 12, [createButton, result]))
        page.add(actions)
        let progressGroup = PreferencesGroup(title: "")
        progressGroup.add(stack)
        page.add(progressGroup)

        toolbar.content = page
        dialog.child = toolbar
    }

    private func create() {
        let app = app
        Task { [weak self] in
            guard let self else { return }
            let chooser = FileDialog(title: "Save Bug Report", acceptLabel: "Save")
            chooser.setInitialFolder(XDGUserDirectories().desktop.path)
            guard let path = try? await chooser.save(parent: app.window, suggestedName: BugReportGenerator.defaultFileName) else { return }
            let destination = URL(fileURLWithPath: path)
            self.createButton.isSensitive = false
            self.result.removeAllChildren()
            self.stack.visibleChildName = "progress"
            let generator = BugReportGenerator(
                session: ConnectionControllerBugReportSession(
                    controller: app.connection,
                    hasActiveTransfers: { app.transferModel.hasActiveTransfers },
                    hotplugEnabled: { app.settings.enableUsbHotplug }
                ),
                debugTool: app.options.mock ? MockDiagnosticTool() as any DebugToolRunning : SwiftMTPDiagnosticTool(),
                diagnostics: .live(settings: app.settings, batchStore: app.batchStore),
                outputDirectory: destination.deletingLastPathComponent(),
                fileName: destination.lastPathComponent
            )
            do {
                let url = try await generator.generate { [weak self] stage in self?.stageStarted(stage) }
                self.finishStages()
                self.showResult(url)
            } catch {
                self.finishStages()
                let label = Label(error.localizedDescription).css("error")
                label.wraps = true
                self.result.append(label)
                self.createButton.isSensitive = true
            }
        }
    }

    private func stageStarted(_ stage: BugReportStage) {
        for (other, row) in stageRows {
            if other < stage {
                row.spinner.isVisible = false
                row.icon.isVisible = true
                row.icon.iconName = "object-select-symbolic"
                row.icon.removeCSSClass("dim-label")
                row.icon.addCSSClass("success")
            } else if other == stage {
                row.icon.isVisible = false
                row.spinner.isVisible = true
            }
        }
    }

    private func finishStages() {
        for row in stageRows.values {
            row.spinner.isVisible = false
            row.icon.isVisible = true
            row.icon.iconName = "object-select-symbolic"
            row.icon.removeCSSClass("dim-label")
            row.icon.addCSSClass("success")
        }
    }

    private func showResult(_ url: URL) {
        let saved = Label("Saved \(url.lastPathComponent) to \(url.deletingLastPathComponent().path).").css("success")
        saved.wraps = true
        saved.justifyCenter = true
        let show = Button("Show in Files", iconName: "folder-open-symbolic").css("pill")
        show.onClicked { [weak self] in Launcher.showInFileManager(path: url.path, parent: self?.app.window) }
        let issue = Button("Open Issue Page", iconName: "web-browser-symbolic").css("pill", "suggested-action")
        issue.onClicked { [weak self] in
            let link = BugReportLinks.newIssueURL(
                appVersion: AppVersion.current,
                linuxVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                reportFileName: url.lastPathComponent
            )
            Launcher.open(uri: link.absoluteString, parent: self?.app.window)
        }
        result.append(saved)
        result.append(Box(.horizontal, spacing: 12, [show, issue]).align(h: .center))
        createButton.isSensitive = true
    }
}

/// `--mock` has no USB device to diagnose; the report says so.
struct MockDiagnosticTool: DebugToolRunning {
    var reportItem: BugReportItem { .deviceDiagnostic }
    func run() async -> DebugToolResult {
        DebugToolResult(name: "SwiftMTP", report: "Skipped: the app was running with the built-in mock phone (--mock).\n", termination: .completed)
    }
}
