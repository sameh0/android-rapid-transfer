import ARTGtk
import CGtk
import Dispatch

/// The name column's cell: icon + label, recycled across rows.
@MainActor
final class NameCell: ListCell {
    let root: Widget
    let icon = Image(iconName: "text-x-generic-symbolic")
    let label = Label()

    init() {
        label.ellipsis = .middle
        label.align(h: .start).expand(h: true)
        root = Box(.horizontal, spacing: 8, [icon, label])
    }
}

/// The demo file table: a 10,000-row column view with sortable name, size
/// and date columns. Shared by the gallery and the self-test.
@MainActor
final class FileTable {
    let store: ListStore<FileRow>
    let view: ColumnView<FileRow>
    let nameColumn: ColumnViewColumn<FileRow>
    let sizeColumn: ColumnViewColumn<FileRow>
    let dateColumn: ColumnViewColumn<FileRow>
    let nameFactory: ListItemFactory<FileRow, NameCell>

    init(rows: [FileRow]) {
        store = ListStore(rows)
        view = ColumnView(store: store, selection: .multiple)
        view.showsColumnSeparators = false
        view.css("data-table")

        // Folders first, then case-insensitive name.
        let byName = Sorter<FileRow> { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.lowercasedName < b.lowercasedName
        }
        nameFactory = ListItemFactory(
            setup: { NameCell() },
            bind: { cell, row, _ in
                cell.icon.iconName = row.iconName
                cell.label.text = row.name
            })
        nameColumn = ColumnViewColumn("Name", expand: true, sorter: byName, factory: nameFactory)

        sizeColumn = ColumnViewColumn("Size", fixedWidth: 110, sorter: Sorter(\.size), factory: ListItemFactory<FileRow, Label>(
            setup: { Label().align(h: .end).css("numeric", "dim-label") },
            bind: { label, row, _ in label.text = row.sizeText }))

        dateColumn = ColumnViewColumn("Modified", fixedWidth: 170, sorter: Sorter(\.modified), factory: ListItemFactory<FileRow, Label>(
            setup: { Label().align(h: .start).css("numeric", "dim-label") },
            bind: { label, row, _ in label.text = row.modifiedText }))

        view.append(nameColumn)
        view.append(sizeColumn)
        view.append(dateColumn)
        view.sort(by: nameColumn)
    }
}

/// The gallery window proving the ARTGtk layer.
@MainActor
final class Gallery {
    let app: Application
    let model = GalleryModel()
    let window: ApplicationWindow
    let toasts = ToastOverlay()
    let table: FileTable
    private var copyTask: Task<Void, Never>?
    private var liveness: MotionLiveness?
    private var showHiddenAction: SimpleAction?
    private weak var startButton: Button?
    private weak var sideStack: ViewStack?

    init(app: Application) {
        self.app = app
        window = ApplicationWindow(application: app)
        table = FileTable(rows: FileRow.sample(count: 10_000))
        window.title = "ARTGtk Gallery"
        window.setDefaultSize(width: 1280, height: 820)
        loadCSS()
        installActions()
        window.content = toasts
        toasts.child = makeToolbarView()
        liveness = MotionLiveness(window: window)
    }

    func present() { window.present() }

    /// `--page transfer|drop|grid`: which side page to show.
    func show(page: String) { sideStack?.visibleChildName = page }

    /// `--autoplay`: select a few rows, start a copy and show a toast, so a
    /// screenshot shows the moving parts.
    func autoplay() {
        let selection = table.view.pipeline.selection
        for position in [3, 4, 6] { selection.select(position, exclusive: false) }
        startButton?.emit("clicked")
        toasts.show("Autoplay: copying 100 files")
    }

    // MARK: Layout

    private func makeToolbarView() -> Widget {
        let model = model
        let toolbar = ToolbarView()

        let header = HeaderBar()
        let title = WindowTitle(title: "ARTGtk Gallery")
        title.bind { $0.subtitle = model.summary }
        header.titleWidget = title
        header.packStart(Button(iconName: "folder-open-symbolic", tooltip: "Choose Folder… (Ctrl+O)").then { $0.actionName = "win.choose-folder" })
        header.packEnd(MenuButton(menu: makeMenu(), primary: true))
        header.packEnd(Button(iconName: "dialog-warning-symbolic", tooltip: "Alert… (Ctrl+D)").then { $0.actionName = "win.alert" })
        toolbar.addTopBar(header)

        let banner = Banner("This window exercises the Linux UI layer: lists, bindings, dialogs, drag and drop.", buttonLabel: "Dismiss")
        banner.isRevealed = true
        banner.onButtonClicked { [weak banner] in banner?.isRevealed = false }
        toolbar.addTopBar(banner)

        let paned = Paned(.horizontal, start: makeFilePane(), end: makeSidePane())
        paned.position = 760
        paned.configure(resizeStart: true, resizeEnd: true)
        toolbar.content = paned

        let status = Label().align(h: .start).css("dim-label", "caption")
        status.bind { $0.text = model.isRunning ? model.status : model.summary }
        let folder = Label().align(h: .end).expand(h: true).css("dim-label", "caption")
        folder.ellipsis = .start
        folder.bind { $0.text = model.chosenFolder.map { "Destination: \($0)" } ?? "No destination chosen" }
        toolbar.addBottomBar(Box(.horizontal, spacing: 12, [status, folder]).css("status-bar"))
        return toolbar
    }

    private func makeFilePane() -> Widget {
        let search = SearchEntry(placeholder: "Filter 10,000 items")
        search.margins(top: 8, bottom: 8, start: 12, end: 12)
        let table = table
        let model = model
        search.onSearchChanged { [weak search] in
            let query = (search?.text ?? "").lowercased()
            table.view.pipeline.filter.update { query.isEmpty || $0.lowercasedName.contains(query) }
            model.visibleCount = table.view.pipeline.visibleCount
        }
        model.itemCount = table.store.count
        model.visibleCount = table.view.pipeline.visibleCount
        table.view.pipeline.selection.onSelectionChanged {
            model.selectedCount = table.view.pipeline.selection.selectedPositions.count
        }
        table.view.onActivate { [weak self] row, _ in
            self?.toasts.show("Opened “\(row.name)”")
        }

        // Drag rows out: offers the selection as files (demo: real paths under /tmp).
        let drag = FileDragSource(actions: [.copy])
        drag.onPrepare { _, _ in
            let rows = table.view.pipeline.selectedItems
            return rows.isEmpty ? nil : ["/tmp"]
        }
        table.view.add(drag)

        let scroller = ScrolledWindow(table.view).expand(h: true, v: true)
        return Box(.vertical, spacing: 0, [search, scroller]).sizeRequest(width: 420)
    }

    private func makeSidePane() -> Widget {
        let stack = ViewStack()
        stack.add(makeTransferPage(), name: "transfer", title: "Transfer", iconName: "folder-download-symbolic")
        stack.add(makeDropPage(), name: "drop", title: "Drop", iconName: "document-send-symbolic")
        stack.add(makeGridPage(), name: "grid", title: "Grid", iconName: "view-grid-symbolic")
        sideStack = stack
        let switcher = ViewSwitcher(stack: stack).margins(8)
        return Box(.vertical, spacing: 0, [switcher, stack.expand(v: true)]).sizeRequest(width: 360)
    }

    private func makeTransferPage() -> Widget {
        let model = model
        let heading = Label("Copy queue").align(h: .start).css("title-2")
        let progress = ProgressBar()
        progress.bind { $0.fraction = model.progress; $0.text = model.isRunning ? "\(Int(model.progress * 100))%" : nil }
        let status = Label().align(h: .start).css("dim-label")
        status.wraps = true
        status.bind { $0.text = model.status }

        let spinner = Spinner().sizeRequest(width: 24, height: 24)
        let spinnerReveal = Revealer(spinner, transition: .crossfade, duration: Motion.Duration.quick)
        spinnerReveal.bind { $0.isRevealed = model.isRunning }

        let done = Image(iconName: "object-select-symbolic", pixelSize: 48).css("success")
        done.opacity = 0

        let start = Button("Start Copy", iconName: "media-playback-start-symbolic").css("suggested-action", "pill")
        start.bind { $0.isSensitive = !model.isRunning }
        startButton = start
        start.onClicked { [weak self, weak done] in
            guard let self, let done else { return }
            self.startCopy(celebrate: done)
        }
        let cancel = Button("Cancel").css("pill")
        cancel.bind { $0.isSensitive = model.isRunning }
        cancel.onClicked { [weak self] in self?.copyTask?.cancel() }

        let buttons = Box(.horizontal, spacing: 12, [start, cancel, spinnerReveal]).align(h: .start)
        let copied = Label().align(h: .start).css("caption", "dim-label")
        copied.bind { $0.text = "Files copied this session: \(model.copiedFiles)" }
        return Box(.vertical, spacing: 16, [heading, progress, status, buttons, copied, done.align(h: .center)]).margins(24)
    }

    private func makeDropPage() -> Widget {
        let model = model
        let page = StatusPage(title: "Drop Files Here", description: "Drag files from the file manager.", iconName: "folder-download-symbolic")
        page.css("drop-zone")
        page.bind { page in
            if model.droppedPaths.isEmpty { return }
            page.title = "\(model.droppedPaths.count) item(s) dropped"
            page.descriptionText = model.droppedPaths.prefix(5).joined(separator: "\n")
        }
        let drop = FileDropTarget()
        drop.onDrop { paths, _, _ in
            for path in paths { print("DROPPED \(path)") }
            model.droppedPaths = paths
            return !paths.isEmpty
        }
        drop.onHoverChanged { [weak page] hovering in page?.setCSSClass("drop-hover", hovering) }
        page.add(drop)
        return page
    }

    private func makeGridPage() -> Widget {
        let store = ListStore(FileRow.sample(count: 300))
        let factory = ListItemFactory<FileRow, GridCell>(
            setup: { GridCell() },
            bind: { cell, row, _ in
                cell.icon.iconName = row.iconName
                cell.label.text = row.name
            })
        let grid = GridView(store: store, factory: factory, selection: .multiple)
        grid.maxColumns = 6
        return ScrolledWindow(grid).expand(h: true, v: true)
    }

    // MARK: Behaviour

    /// A background task reporting progress through the main actor.
    private func startCopy(celebrate done: Image) {
        let model = model
        model.isRunning = true
        model.progress = 0
        done.opacity = 0
        copyTask = Task.detached(priority: .userInitiated) { [weak self] in
            let total = 100
            for index in 1...total {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
                await MainActor.run {
                    model.progress = Double(index) / Double(total)
                    model.status = "Copying IMG_\(20_260_000 + index).jpg (\(index) of \(total))"
                    model.copiedFiles += 1
                }
            }
            await MainActor.run {
                let finished = model.progress >= 1
                model.isRunning = false
                model.status = finished ? "Copied \(total) files" : "Cancelled"
                guard let self else { return }
                self.toasts.show(finished ? "Copied \(total) files" : "Copy cancelled")
                if finished {
                    // Celebrate: fade in (opacity clamps itself) and pop the icon size.
                    Animation.spring(on: done, Motion.celebrate, from: 0, to: 1) { [weak done] value in
                        done?.opacity = value
                        done?.pixelSize = Int32(48 * (0.6 + 0.4 * value))
                    }.play()
                }
            }
        }
    }

    private func makeMenu() -> Menu {
        let main = Menu()
        main.append("Show Toast", action: "app.toast")
        main.append("Alert…", action: "win.alert")
        main.append("Choose Folder…", action: "win.choose-folder")
        main.append("Show Hidden Files", action: "win.show-hidden")
        main.append("Send Notification", action: "app.notify")
        let second = Menu()
        second.append("Preferences", action: "app.preferences")
        second.append("Quit", action: "app.quit")
        let menu = Menu()
        menu.appendSection(main)
        menu.appendSection(second)
        return menu
    }

    private func installActions() {
        let model = model
        app.addAction("quit") { [weak self] in self?.window.close() }
        app.setAccelerators(["<Control>q"], for: "app.quit")
        app.addAction("toast") { [weak self] in self?.toasts.show("Hello from ARTGtk") }
        app.setAccelerators(["<Control>t"], for: "app.toast")
        app.addAction("notify") { [weak self] in
            self?.app.send(DesktopNotification(title: "Copy finished", body: "\(model.copiedFiles) files copied", iconName: "folder-download-symbolic"), id: "copy")
        }
        app.addAction("preferences") { [weak self] in self?.showPreferences() }
        app.setAccelerators(["<Control>comma"], for: "app.preferences")

        window.addAction("alert") { [weak self] in self?.showAlert() }
        app.setAccelerators(["<Control>d"], for: "win.alert")
        window.addAction("choose-folder") { [weak self] in self?.chooseFolder() }
        app.setAccelerators(["<Control>o"], for: "win.choose-folder")
        let showHidden = SimpleAction("show-hidden", state: false) { model.showHidden = $0 }
        showHiddenAction = showHidden
        window.add(showHidden)
        app.setAccelerators(["<Control>h"], for: "win.show-hidden")
    }

    private func showAlert() {
        let alert = AlertDialog(heading: "Replace Existing File?", body: "“IMG_20260042.jpg” already exists in the destination.")
        alert.addResponse("cancel", "Cancel")
        alert.addResponse("skip", "Skip")
        alert.addResponse("replace", "Replace", appearance: .destructive)
        alert.defaultResponse = "skip"
        alert.closeResponse = "cancel"
        Task { @MainActor in
            let response = await alert.choose(parent: window)
            print("ALERT response=\(response)")
            toasts.show("Alert answered: \(response)")
        }
    }

    private func chooseFolder() {
        let dialog = FileDialog(title: "Choose Destination", acceptLabel: "Choose")
        Task { @MainActor in
            do {
                let folder = try await dialog.selectFolder(parent: window)
                print("FOLDER \(folder ?? "(cancelled)")")
                if let folder { model.chosenFolder = folder }
            } catch {
                toasts.show("Folder chooser failed: \(error)")
            }
        }
    }

    private func showPreferences() {
        let model = model
        let dialog = PreferencesDialog()
        let page = PreferencesPage(title: "General", iconName: "preferences-system-symbolic")
        let group = PreferencesGroup(title: "Browsing", description: "Bound to the same observable model as the menu toggle.")
        let hidden = SwitchRow(title: "Show Hidden Files", subtitle: "Files whose names start with a dot")
        hidden.bind { $0.isOn = model.showHidden }
        hidden.onToggled { [weak hidden, weak self] in
            guard let hidden, model.showHidden != hidden.isOn else { return }
            model.showHidden = hidden.isOn
            self?.showHiddenAction?.boolState = hidden.isOn
        }
        group.add(hidden)
        let destination = ActionRow(title: "Destination")
        destination.bind { $0.subtitle = model.chosenFolder ?? "Not set" }
        let choose = Button("Choose…").align(v: .center)
        choose.actionName = "win.choose-folder"
        destination.addSuffix(choose)
        group.add(destination)
        page.add(group)
        dialog.add(page)
        dialog.present(parent: window)
    }

    private func loadCSS() {
        CSS.load("""
        .drop-zone { margin: 24px; border-radius: 12px; border: 2px dashed alpha(currentColor, 0.2);
                     transition: background-color 150ms ease-out, border-color 150ms ease-out; }
        .drop-zone.drop-hover { background-color: alpha(@accent_bg_color, 0.12); border-color: @accent_bg_color; }
        .status-bar { padding: 4px 12px; }
        .grid-cell { padding: 8px; }
        """)
    }
}

@MainActor
final class GridCell: ListCell {
    let root: Widget
    let icon = Image(iconName: "text-x-generic-symbolic", pixelSize: 48)
    let label = Label()

    init() {
        label.ellipsis = .middle
        label.css("caption")
        root = Box(.vertical, spacing: 6, [icon, label]).css("grid-cell").sizeRequest(width: 96)
    }
}

extension Widget {
    /// Configure inline: `Button(...).then { $0.actionName = "win.x" }`.
    @discardableResult
    func then(_ body: (Self) -> Void) -> Self {
        body(self)
        return self
    }
}
