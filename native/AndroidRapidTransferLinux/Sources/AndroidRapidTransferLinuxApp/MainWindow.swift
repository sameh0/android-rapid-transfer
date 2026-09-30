import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// The main window: header bar, the computer and phone panes side by side,
/// and the copies panel along the bottom.
@MainActor
final class MainWindow: WindowServices, DevicePaneDelegate {
    let window: ApplicationWindow
    unowned let app: AppController
    let toasts = ToastOverlay()
    private let windowTitle = WindowTitle(title: AppIdentity.name)
    private let paned = Paned(.horizontal)
    private(set) var computerPane: LocalPane!
    private(set) var devicePane: DevicePane!
    private(set) var transferPanel: TransferPanel!
    private(set) var activePane: BrowserPaneKind = .device
    private(set) var conflictDialog: ConflictDialog?
    private var operationAlert: AlertDialog?
    private var liveness: MotionLiveness?
    private let bag = ObserverBag()
    private var toggleLocalPaneAction: SimpleAction?
    private var didAppear = false

    init(app: AppController) {
        self.app = app
        window = ApplicationWindow(application: app.application)
        window.title = AppIdentity.name
        window.setDefaultSize(width: 1240, height: 760)
        window.sizeRequest(width: 900, height: 560)
        computerPane = LocalPane(model: app.localModel, transferModel: app.transferModel, settings: app.settings, services: self)
        devicePane = DevicePane(controller: app.connection, transferModel: app.transferModel, settings: app.settings,
                                services: self, delegate: self)
        transferPanel = TransferPanel(model: app.transferModel, services: self)
        buildLayout()
        installActions()
        installBindings()
        liveness = MotionLiveness(window: window)
        window.onCloseRequest { [weak self] in
            self?.app.requestQuit()
            return true
        }
        window.onMap { [weak self] in self?.windowAppeared() }
    }

    func present() { window.present() }

    // MARK: - Layout

    private func buildLayout() {
        let toolbar = ToolbarView()
        let header = HeaderBar()
        header.titleWidget = windowTitle
        header.packEnd(MenuButton(iconName: "open-menu-symbolic", menu: makeMainMenu(), primary: true).then {
            $0.tooltip = "Main Menu"
        })
        let panelToggle = ToggleButton(iconName: "folder-download-symbolic", tooltip: "Show Copies")
        panelToggle.css("flat")
        let transferModel = app.transferModel
        panelToggle.bind { button in
            button.isVisible = transferModel.isPanelVisible
            if button.isActive != transferModel.isPanelExpanded { button.isActive = transferModel.isPanelExpanded }
        }
        panelToggle.onToggled { [weak panelToggle] in
            guard let panelToggle, panelToggle.isActive != transferModel.isPanelExpanded else { return }
            transferModel.togglePanel()
        }
        header.packEnd(panelToggle)
        let localToggle = ToggleButton(iconName: "computer-symbolic", tooltip: "Show This Computer (F9)")
        localToggle.css("flat")
        localToggle.actionName = "win.show-local-pane"
        header.packStart(localToggle)
        toolbar.addTopBar(header)

        if app.previousSessionEndedAbnormally {
            let banner = Banner("\(AppIdentity.name) didn’t quit normally last time.", buttonLabel: "Report a Bug…")
            banner.isRevealed = true
            banner.onButtonClicked { [weak self, weak banner] in
                banner?.isRevealed = false
                self?.app.presentBugReport()
            }
            toolbar.addTopBar(banner)
        }

        paned.hasWideHandle = false
        paned.configure(resizeStart: true, resizeEnd: true, shrinkStart: false, shrinkEnd: false)
        computerPane.root.sizeRequest(width: 380)
        devicePane.root.sizeRequest(width: 420)
        let content = Box(.vertical, spacing: 0)
        paned.expand(h: true, v: true)
        content.append(paned)
        content.append(transferPanel.root)
        toolbar.content = content
        toasts.child = toolbar
        window.content = toasts
        arrangePanes()
    }

    private func arrangePanes() {
        let settings = app.settings
        paned.start = nil
        paned.end = nil
        let local = computerPane.root
        let device = devicePane.root
        local.isVisible = settings.showLocalPane
        if settings.localPaneOnLeft {
            paned.start = local
            paned.end = device
        } else {
            paned.start = device
            paned.end = local
        }
        if settings.showLocalPane, paned.position <= 0 {
            paned.position = 560
        }
        if !settings.showLocalPane, activePane == .local { activePane = .device }
    }

    private func makeMainMenu() -> Menu {
        let menu = Menu()
        let view = Menu()
        view.append("Show This Computer", action: "win.show-local-pane")
        view.append("Swap Panes", action: "win.swap-panes")
        menu.appendSection(view)
        let copies = Menu()
        copies.append("Resume Copies…", action: "app.resume-copies")
        menu.appendSection(copies)
        let settings = Menu()
        settings.append("Preferences", action: "app.preferences")
        settings.append("Keyboard Shortcuts", action: "app.shortcuts")
        menu.appendSection(settings)
        let help = Menu()
        help.append("Troubleshooting & FAQ", action: "app.help")
        help.append("Connecting Your Phone…", action: "app.connection-help")
        help.append("Report a Bug…", action: "app.report-bug")
        help.append("Privacy", action: "app.privacy")
        help.append("About \(AppIdentity.name)", action: "app.about")
        menu.appendSection(help)
        menu.appendSection(Menu().appending("Quit", action: "app.quit"))
        return menu
    }

    // MARK: - Actions

    private func installActions() {
        window.addAction("new-folder") { [weak self] in self?.withActivePane { $0.presentNewFolder() } ?? () }
        window.addAction("refresh") { [weak self] in self?.withActivePane { $0.refresh() } ?? () }
        window.addAction("add-to-queue") { [weak self] in
            self?.withActivePaneRoot { $0.activateAction("pane.add-to-queue") }
        }
        window.addAction("switch-pane") { [weak self] in self?.switchPane() }
        window.addAction("swap-panes") { [weak self] in
            guard let self else { return }
            self.app.settings.localPaneOnLeft.toggle()
        }
        let settings = app.settings
        let toggle = SimpleAction("show-local-pane", state: settings.showLocalPane) { value in
            if settings.showLocalPane != value { settings.showLocalPane = value }
        }
        window.add(toggle)
        toggleLocalPaneAction = toggle
    }

    /// Runs `body` on the pane that last had focus, for window-wide shortcuts.
    private func withActivePane(_ body: (PaneCommands) -> Void) {
        if activePane == .local, app.settings.showLocalPane {
            body(computerPane.pane)
        } else if let browser = devicePane.browser, devicePane.phase == .connected {
            body(browser)
        }
    }

    private func withActivePaneRoot(_ body: (Widget) -> Void) {
        withActivePane { body($0.paneRoot) }
    }

    private func switchPane() {
        guard app.settings.showLocalPane else { return }
        let target: BrowserPaneKind = activePane == .local ? .device : .local
        if target == .local {
            computerPane.pane.focusContent()
        } else if let browser = devicePane.browser {
            browser.focusContent()
        }
        activePane = target
    }

    // MARK: - Bindings

    private func installBindings() {
        let settings = app.settings
        let connection = app.connection
        let transferModel = app.transferModel
        bag.onChange({ [settings] in [settings.showLocalPane, settings.localPaneOnLeft] }) { [weak self] _ in
            self?.arrangePanes()
            if let action = self?.toggleLocalPaneAction, action.boolState != settings.showLocalPane {
                action.boolState = settings.showLocalPane
            }
        }
        windowTitle.bind { title in
            switch ConnectionPanePhase(controller: connection) {
            case .connected:
                title.subtitle = connection.deviceModel?.title ?? "Phone connected"
            case .detecting:
                title.subtitle = "Connecting…"
            case .reconnecting:
                title.subtitle = "Reconnecting…"
            case .needsReplug:
                title.subtitle = "Replug the phone"
            case .failed:
                title.subtitle = "Couldn’t connect"
            case .waiting:
                title.subtitle = "No phone connected"
            }
        }
        bag.onChange(initial: true, { transferModel.conflictPrompt }) { [weak self] prompt in
            self?.conflictPromptChanged(prompt)
        }
        bag.onChange(initial: true, { transferModel.isShowingOperationError }) { [weak self] showing in
            if showing { self?.presentOperationError() }
        }
    }

    private func conflictPromptChanged(_ prompt: FileConflictPrompt?) {
        if let current = conflictDialog, current.prompt.id != prompt?.id {
            current.withdraw()
            conflictDialog = nil
        }
        guard let prompt, conflictDialog == nil else { return }
        let transferModel = app.transferModel
        let dialog = ConflictDialog(prompt: prompt) { resolution, appliesToAll in
            transferModel.resolveConflict(resolution, appliesToAll: appliesToAll)
        }
        conflictDialog = dialog
        dialog.dialog.onClosed { [weak self, weak dialog] in
            if self?.conflictDialog === dialog { self?.conflictDialog = nil }
        }
        dialog.dialog.present(parent: window)
    }

    private func presentOperationError() {
        guard operationAlert == nil else { return }
        let transferModel = app.transferModel
        let alert = AlertDialog(heading: "Couldn’t Complete the Operation",
                                body: transferModel.operationErrorMessage ?? "The operation could not be completed.")
        alert.addResponse("ok", "OK")
        operationAlert = alert
        Task { [weak self] in
            _ = await alert.choose(parent: self?.window)
            transferModel.operationErrorMessage = nil
            transferModel.isShowingOperationError = false
            self?.operationAlert = nil
        }
    }

    private func windowAppeared() {
        guard !didAppear else { return }
        didAppear = true
        app.windowAppeared()
        if app.settings.showLocalPane {
            activePane = .local
            computerPane.pane.focusContent()
        }
    }

    // MARK: - WindowServices

    func toast(_ text: String) {
        toasts.show(text, timeout: 3)
    }

    func paneDidFocus(_ kind: BrowserPaneKind) {
        activePane = kind
    }

    // MARK: - DevicePaneDelegate

    func showConnectionHelp() { app.presentOnboarding(startingAtConnection: true) }
    func showTroubleshooting() { app.presentHelp() }

    func presentDateRangeCopy(model: DeviceBrowserViewModel) {
        guard let storageID = model.selectedStorageID else { return }
        let roots = model.selectedEntries.filter(\.isDirectory).map(\.location)
        guard !roots.isEmpty else { return }
        let transferModel = app.transferModel
        let destination = app.settings.showLocalPane ? transferModel.defaultDownloadDestination : DefaultDestinations.downloads
        let scanner = DeviceFolderScanner { path, objectId, onProgress in
            try await model.listDirectoryForScan(path, objectId: objectId, storageID: storageID, onProgress: onProgress)
        }
        var sheet: DateRangeDialog?
        let viewModel = DateRangeCopyViewModel(roots: roots, destination: destination, scanner: scanner) { plan, selectedDestination in
            sheet?.close()
            Task {
                await transferModel.enqueueDateRangeCopy(plan, destination: selectedDestination, storageID: storageID)
            }
        }
        let dialog = DateRangeDialog(model: viewModel, parent: window)
        sheet = dialog
        dialog.present()
    }
}

/// The commands the window forwards to whichever pane is active.
@MainActor
protocol PaneCommands: AnyObject {
    var paneRoot: Widget { get }
    func presentNewFolder()
    func refresh()
    func focusContent()
}

extension BrowserPane: PaneCommands {
    var paneRoot: Widget { root }
}
