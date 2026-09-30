import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// Copy by Date Range: pick the dates and what to skip, scan the selected
/// phone folders, review the matches, then copy them — driven entirely by
/// Core's ``DateRangeCopyViewModel``.
@MainActor
final class DateRangeDialog {
    let dialog = Dialog(title: "Copy by Date Range", width: 600, height: 700)
    let model: DateRangeCopyViewModel
    private weak var parent: Window?
    private let pages = Stack(transition: .crossfade, duration: Motion.Duration.standard)
    private let reviewList = ListBox()
    private let reviewSummary = Label().css("heading")
    private let scanPage = StatusPage(title: "Scanning the Phone…")
    private var shownPhase = ""
    private let bag = ObserverBag()

    init(model: DateRangeCopyViewModel, parent: Window) {
        self.model = model
        self.parent = parent
        let toolbar = ToolbarView()
        toolbar.addTopBar(HeaderBar())
        pages.add(configurePage(), name: "configuring")
        pages.add(scanningPage(), name: "scanning")
        pages.add(reviewPage(), name: "reviewing")
        toolbar.content = pages
        dialog.child = toolbar
        bag.onChange(initial: true, { [model] in Self.phaseName(model.phase) }) { [weak self] name in
            self?.pages.visibleChildName = name
            if name == "reviewing" { self?.rebuildReview() }
        }
        dialog.onClosed { [model] in model.cancelScan() }
    }

    func present() {
        OpenDialogs.keep(self, while: dialog)
        dialog.present(parent: parent)
    }

    func close() { dialog.forceClose() }

    private static func phaseName(_ phase: DateRangeCopyViewModel.Phase) -> String {
        switch phase {
        case .configuring: "configuring"
        case .scanning: "scanning"
        case .reviewing: "reviewing"
        }
    }

    // MARK: - Configure

    private func configurePage() -> Widget {
        let model = model
        let page = PreferencesPage(title: "Range")

        let folders = PreferencesGroup(title: "Folders",
                                       description: model.roots.count == 1 ? "Scans this folder and everything in it." : "Scans these folders and everything in them.")
        for root in model.roots {
            let row = ActionRow(title: (root as NSString).lastPathComponent, subtitle: root)
            row.addPrefix(Image(iconName: "folder-symbolic"))
            folders.add(row)
        }
        page.add(folders)

        let range = PreferencesGroup(title: "Date Range", description: "Files modified on these days are copied.")
        let fromRow = ActionRow(title: "From")
        fromRow.addSuffix(datePicker(get: { model.startDate }, set: { model.startDate = $0 }))
        range.add(fromRow)
        let untilSwitch = SwitchRow(title: "Until a specific day", subtitle: "Otherwise, up to now")
        untilSwitch.isOn = model.hasEndDate
        untilSwitch.onToggled { [weak untilSwitch] in model.hasEndDate = untilSwitch?.isOn ?? false }
        range.add(untilSwitch)
        let toRow = ActionRow(title: "To")
        toRow.addSuffix(datePicker(get: { model.endDate }, set: { model.endDate = $0 }))
        toRow.bind { $0.isSensitive = model.hasEndDate }
        range.add(toRow)
        page.add(range)

        let skip = PreferencesGroup(title: "Skip")
        let dots = SwitchRow(title: "Hidden files and folders", subtitle: "Names starting with a dot")
        dots.isOn = model.ignoreDotFiles
        dots.onToggled { [weak dots] in model.ignoreDotFiles = dots?.isOn ?? false }
        let caches = SwitchRow(title: "Cache files", subtitle: "Thumbnails and app caches")
        caches.isOn = model.ignoreCacheFiles
        caches.onToggled { [weak caches] in model.ignoreCacheFiles = caches?.isOn ?? false }
        skip.add(dots)
        skip.add(caches)
        let extensions = ActionRow(title: "File types")
        let checks = Box(.horizontal, spacing: 4)
        checks.bind { box in
            box.removeAllChildren()
            for ext in model.extensionOptions {
                let check = CheckButton(ext, isActive: model.isIgnoringExtension(ext))
                check.onToggled { [weak check] in model.setIgnoringExtension(check?.isActive ?? false, fileExtension: ext) }
                box.append(check)
            }
        }
        extensions.addSuffix(checks)
        skip.add(extensions)
        let custom = EntryRow(title: "Add a file type to skip (for example .tmp)")
        let add = Button(iconName: "list-add-symbolic", tooltip: "Add").css("flat").align(v: .center)
        custom.onChanged { [weak custom] in model.customExtensionInput = custom?.text ?? "" }
        let addExtension: @MainActor () -> Void = { [weak custom] in
            guard model.canAddCustomExtension else { return }
            model.addCustomExtension()
            custom?.text = ""
        }
        add.onClicked(addExtension)
        custom.onEntryActivated(addExtension)
        add.bind { $0.isSensitive = model.canAddCustomExtension }
        custom.addSuffix(add)
        skip.add(custom)
        page.add(skip)

        let destination = PreferencesGroup(title: "Copy To")
        let destinationRow = ActionRow(title: "Folder")
        destinationRow.bind { $0.subtitle = model.destination }
        let choose = Button("Choose…").css("flat").align(v: .center)
        choose.onClicked { [weak self] in
            Task {
                let chooser = FileDialog(title: "Copy To", acceptLabel: "Choose")
                chooser.setInitialFolder(model.destination)
                if let folder = try? await chooser.selectFolder(parent: self?.parent) { model.destination = folder }
            }
        }
        destinationRow.addSuffix(choose)
        destination.add(destinationRow)
        page.add(destination)

        let preview = Button("Preview Files").css("pill")
        preview.onClicked { model.startScan(intent: .preview) }
        let copyNow = Button("Copy Now").css("pill", "suggested-action")
        copyNow.onClicked { model.startScan(intent: .copyNow) }
        let buttons = Box(.horizontal, spacing: 12, [preview, copyNow]).align(h: .center)
        buttons.bind { box in box.isSensitive = model.canStartScan }
        let buttonGroup = PreferencesGroup(title: "")
        buttonGroup.add(buttons)
        page.add(buttonGroup)
        return page
    }

    /// A button showing a date that opens a calendar.
    private func datePicker(get: @escaping @MainActor () -> Date, set: @escaping @MainActor (Date) -> Void) -> Widget {
        let calendar = CalendarView()
        let popover = Popover(calendar)
        let button = MenuButton(iconName: "x-office-calendar-symbolic", label: nil, popover: popover)
        button.align(v: .center)
        button.bind { button in
            let date = get()
            button.label = date.formatted(date: .abbreviated, time: .omitted)
            let parts = Foundation.Calendar.current.dateComponents([.year, .month, .day], from: date)
            let current = calendar.selectedDay
            if current.year != parts.year || current.month != parts.month || current.day != parts.day {
                calendar.selectedDay = (parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
            }
        }
        calendar.onDaySelected { [weak calendar] in
            guard let calendar else { return }
            let day = calendar.selectedDay
            var components = DateComponents()
            components.year = day.year
            components.month = day.month
            components.day = day.day
            components.hour = 12
            if let date = Foundation.Calendar.current.date(from: components) { set(date) }
        }
        return button
    }

    // MARK: - Scanning

    private func scanningPage() -> Widget {
        let model = model
        let spinner = Spinner().sizeRequest(width: 40, height: 40).align(h: .center)
        let path = Label().css("caption", "dim-label", "monospace")
        path.ellipsis = .middle
        path.maxWidthChars = 48
        let cancel = Button("Cancel").css("pill").align(h: .center)
        cancel.onClicked { model.cancelScan() }
        scanPage.child = Box(.vertical, spacing: 12, [spinner, path, cancel])
        scanPage.bind { page in
            if case let .scanning(progress) = model.phase {
                page.descriptionText = "\(Format.count(progress.scannedFolders, "folder")) scanned · \(Format.count(progress.matchedFiles, "matching file"))"
                path.text = model.currentListing?.path ?? progress.currentPath
            }
        }
        return scanPage
    }

    // MARK: - Review

    private func reviewPage() -> Widget {
        let model = model
        let edit = Button("Edit Range").css("pill")
        edit.onClicked { model.editRange() }
        let copy = Button("Copy").css("pill", "suggested-action")
        copy.onClicked { model.copySelection() }
        copy.bind { button in
            button.isSensitive = model.canCopySelection
            button.label = model.selectedFileCount == 1 ? "Copy 1 File" : "Copy \(model.selectedFileCount.formatted()) Files"
        }
        reviewSummary.bind { label in
            label.text = "\(Format.count(model.selectedFileCount, "file")) selected · \(Format.bytes(model.selectedTotalSize))"
        }
        reviewSummary.align(h: .start)
        let scroller = ScrolledWindow(reviewList).expand(v: true)
        scroller.setPolicy(h: .never, v: .automatic)
        let buttons = Box(.horizontal, spacing: 12, [edit, copy]).align(h: .center)
        return Box(.vertical, spacing: 12, [reviewSummary, scroller, buttons]).margins(18)
    }

    private func rebuildReview() {
        reviewList.removeAll()
        guard let result = model.result else { return }
        if result.isCancelled {
            reviewList.append(ActionRow(title: "The scan was stopped early", subtitle: "Only the folders scanned before stopping are included."))
        }
        if !result.failures.isEmpty {
            reviewList.append(ActionRow(title: "\(Format.count(result.failures.count, "folder")) couldn’t be read",
                                        subtitle: result.failures.prefix(3).map(\.path).joined(separator: ", ")))
        }
        if result.matches.isEmpty {
            reviewList.append(ActionRow(title: "No files match", subtitle: "Try a wider date range."))
        }
        let model = model
        for match in result.matches.prefix(2_000) {
            let check = CheckButton("", isActive: model.isIncluded(match))
            check.onToggled { [weak check] in model.setIncluded(check?.isActive ?? false, for: match) }
            let icon = Image(iconName: "text-x-generic", pixelSize: 24)
            icon.setIconNames(EntryIcons.names(for: match.entry))
            let name = Label(match.relativePath).align(h: .start).expand(h: true)
            name.ellipsis = .middle
            let detail = Label("\(Format.bytes(match.size)) · \(Format.date(match.entry.modified))").css("caption", "dim-label", "numeric")
            reviewList.append(Box(.horizontal, spacing: 10, [check, icon, name, detail]).css("date-range-match"))
        }
        if result.matches.count > 2_000 {
            reviewList.append(ActionRow(title: "…and \(result.matches.count - 2_000) more", subtitle: "All of them are copied unless you edit the range."))
        }
    }
}
