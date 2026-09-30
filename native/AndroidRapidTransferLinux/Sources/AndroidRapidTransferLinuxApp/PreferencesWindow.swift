import ARTGtk
import AndroidRapidTransferCore

/// Preferences, bound both ways to Core's ``AppSettings``.
@MainActor
final class PreferencesWindow {
    let dialog = PreferencesDialog()
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        dialog.add(generalPage())
        dialog.add(filesPage())
    }

    func present(parent: Widget?) { dialog.present(parent: parent) }

    // MARK: - Pages

    private func generalPage() -> PreferencesPage {
        let settings = settings
        let page = PreferencesPage(title: "General", iconName: "preferences-system-symbolic")

        let appearance = PreferencesGroup(title: "Appearance")
        let themes: [AppTheme] = [.system, .light, .dark]
        let theme = ComboRow(title: "Style", subtitle: "Follow the desktop, or always use light or dark", choices: ["Follow System", "Light", "Dark"])
        bindChoice(theme, values: themes, get: { settings.theme }, set: { settings.theme = $0 })
        appearance.add(theme)
        page.add(appearance)

        let layout = PreferencesGroup(title: "Layout",
                                      description: "Show your computer’s files next to the phone’s, to copy between them with drag and drop or Ctrl+C and Ctrl+V.")
        let dual = SwitchRow(title: "Show This Computer")
        bindSwitch(dual, get: { settings.showLocalPane }, set: { settings.showLocalPane = $0 })
        let left = SwitchRow(title: "Place This Computer on the left")
        bindSwitch(left, get: { settings.localPaneOnLeft }, set: { settings.localPaneOnLeft = $0 })
        left.bind { $0.isSensitive = settings.showLocalPane }
        layout.add(dual)
        layout.add(left)
        page.add(layout)

        let connection = PreferencesGroup(title: "Connection")
        let hotplug = SwitchRow(title: "Automatically detect USB changes",
                                subtitle: "Finds your phone as soon as it’s plugged in, and notices when it’s unplugged")
        bindSwitch(hotplug, get: { settings.enableUsbHotplug }, set: { settings.enableUsbHotplug = $0 })
        connection.add(hotplug)
        page.add(connection)

        let privacy = PreferencesGroup(title: "Privacy")
        let privacyRow = ActionRow(title: "No analytics or tracking",
                                   subtitle: "Files move only between this computer and your phone.")
        let details = Button("Privacy Details…").css("flat").align(v: .center)
        details.actionName = "app.privacy"
        privacyRow.addSuffix(details)
        privacy.add(privacyRow)
        page.add(privacy)
        return page
    }

    private func filesPage() -> PreferencesPage {
        let settings = settings
        let page = PreferencesPage(title: "Files", iconName: "folder-symbolic")

        let hidden = PreferencesGroup(title: "Hidden Files")
        let localHidden = SwitchRow(title: "Show hidden files on this computer")
        bindSwitch(localHidden, get: { settings.localShowsHiddenFiles }, set: { settings.localShowsHiddenFiles = $0 })
        let deviceHidden = SwitchRow(title: "Show hidden files on the phone")
        bindSwitch(deviceHidden, get: { settings.deviceShowsHiddenFiles }, set: { settings.deviceShowsHiddenFiles = $0 })
        hidden.add(localHidden)
        hidden.add(deviceHidden)
        page.add(hidden)

        let sorting = PreferencesGroup(title: "Sorting and View")
        let foldersFirst = SwitchRow(title: "Show folders first")
        bindSwitch(foldersFirst, get: { settings.showDirectoriesFirst }, set: { settings.showDirectoriesFirst = $0 })
        sorting.add(foldersFirst)
        let modes: [BrowserViewMode] = [.list, .grid]
        let localView = ComboRow(title: "This computer", choices: ["List", "Grid"])
        bindChoice(localView, values: modes, get: { settings.localViewMode }, set: { settings.localViewMode = $0 })
        let deviceView = ComboRow(title: "Phone", choices: ["List", "Grid"])
        bindChoice(deviceView, values: modes, get: { settings.deviceViewMode }, set: { settings.deviceViewMode = $0 })
        sorting.add(localView)
        sorting.add(deviceView)
        let status = SwitchRow(title: "Show status bars", subtitle: "The item count and free space under each pane")
        bindSwitch(status, get: { settings.enableStatusBar }, set: { settings.enableStatusBar = $0 })
        sorting.add(status)
        page.add(sorting)

        let progress = PreferencesGroup(title: "Overall Progress",
                                        description: "Counts the files before a copy starts, so the copies panel can show overall progress. Counting large folders can take from a few seconds to a few minutes.")
        let download = SwitchRow(title: "When copying to this computer")
        bindSwitch(download, get: { settings.preprocessFilesBeforeDownload }, set: { settings.preprocessFilesBeforeDownload = $0 })
        let upload = SwitchRow(title: "When copying to the phone")
        bindSwitch(upload, get: { settings.preprocessFilesBeforeUpload }, set: { settings.preprocessFilesBeforeUpload = $0 })
        progress.add(download)
        progress.add(upload)
        page.add(progress)

        let conflicts = PreferencesGroup(title: "File Conflicts")
        let policies: [FileConflictPolicy] = [.askEveryFile, .askEverySession, .alwaysSkip, .alwaysOverwrite]
        let policy = ComboRow(title: "When a file already exists",
                              choices: ["Ask for every file", "Ask once per session", "Always skip", "Always replace"])
        bindChoice(policy, values: policies, get: { settings.fileConflictPolicy }, set: { settings.fileConflictPolicy = $0 })
        conflicts.add(policy)
        page.add(conflicts)
        return page
    }

    // MARK: - Two-way bindings

    private func bindSwitch(_ row: SwitchRow, get: @escaping @MainActor () -> Bool, set: @escaping @MainActor (Bool) -> Void) {
        row.bind { row in
            let value = get()
            if row.isOn != value { row.isOn = value }
        }
        row.onToggled { [weak row] in
            guard let row, row.isOn != get() else { return }
            set(row.isOn)
        }
    }

    private func bindChoice<Value: Equatable>(_ row: ComboRow, values: [Value], get: @escaping @MainActor () -> Value,
                                              set: @escaping @MainActor (Value) -> Void) {
        row.bind { row in
            let index = values.firstIndex(of: get()) ?? 0
            if row.selectedIndex != index { row.selectedIndex = index }
        }
        row.onSelectionChanged { [weak row] in
            guard let row, values.indices.contains(row.selectedIndex) else { return }
            let value = values[row.selectedIndex]
            if value != get() { set(value) }
        }
    }
}
