import ARTGtk
import AndroidRapidTransferCore
import Foundation
import Observation

/// The pane's filter-as-you-type query.
@MainActor
@Observable
final class PaneSearch {
    var query = ""
}

/// What a pane needs from the window around it.
@MainActor
protocol WindowServices: AnyObject {
    var window: ApplicationWindow { get }
    func toast(_ text: String)
    func paneDidFocus(_ kind: BrowserPaneKind)
}

/// The pane-specific actions a ``BrowserPane`` offers: copying to the other
/// side, the copy queue, pasting and (on the phone) the date-range copy.
/// The `can…` closures read observable state, so bindings follow them.
@MainActor
struct PaneActions {
    var copyTitle: String
    var copyIcon: String
    var copyTooltip: String
    var canCopyToOther: () -> Bool
    var copyToOther: () -> Void
    var canAddToQueue: () -> Bool
    var addToQueue: () -> Void
    var canClipboardCopy: () -> Bool
    var clipboardCopy: () -> Void
    var canPaste: () -> Bool
    var paste: () -> Void
    var navigationDisabled: () -> Bool = { false }
    var dateRange: (() -> Void)?
    var canDateRange: () -> Bool = { false }
    var emptyTitle = "Empty Folder"
    var emptyMessage: String
    var trashLabel = "Delete…"
    /// Replaces the first breadcrumb's label (the phone pane shows the storage).
    var rootLabel: () -> String? = { nil }
}

/// The row a cell shows, attached to the cell's root so a click or drag
/// position can be mapped back to its entry.
final class EntryRef {
    let entry: BrowserEntry
    init(_ entry: BrowserEntry) { self.entry = entry }
}

/// The name column's cell: icon and name.
@MainActor
final class NameCell: ListCell {
    let root: Widget
    let icon = Image(iconName: "text-x-generic", pixelSize: 24)
    let label = Label()

    init() {
        label.ellipsis = .middle
        label.align(h: .start).expand(h: true)
        root = Box(.horizontal, spacing: 10, [icon, label])
    }
}

/// A grid cell: a large icon over the name.
@MainActor
final class GridCell: ListCell {
    let root: Widget
    let icon = Image(iconName: "text-x-generic", pixelSize: 64)
    let label = Label()

    init() {
        label.ellipsis = .middle
        label.wraps = true
        label.lines = 2
        label.justifyCenter = true
        label.maxWidthChars = 14
        label.css("caption")
        root = Box(.vertical, spacing: 6, [icon, label]).css("grid-cell").sizeRequest(width: 112)
    }
}

/// One file browser: breadcrumbs and toolbar, a list or grid of entries,
/// empty/loading states and a status bar, over any Core ``BrowserPaneModel``.
@MainActor
final class BrowserPane<Model: BrowserPaneModel> {
    let model: Model
    let kind: BrowserPaneKind
    let settings: AppSettings
    let actions: PaneActions
    private weak var services: (any WindowServices)?

    let root = Box(.vertical)
    let store = ListStore<BrowserEntry>()
    let columnView: ColumnView<BrowserEntry>
    let gridView: GridView<BrowserEntry>
    /// The widget drags start from and drops land on (the content area).
    let contentArea: Overlay
    private let contentStack = Stack(transition: .crossfade, duration: Motion.Duration.quick)
    private let breadcrumbBox = Box(.horizontal, spacing: 0)
    private let errorBanner = Banner("", buttonLabel: "Dismiss")
    let search = PaneSearch()
    private let searchEntry = SearchEntry(placeholder: "Filter this folder")
    private let searchReveal = Revealer(nil, transition: .slideDown, duration: Motion.Duration.standard)
    private let actionGroup = ActionGroup()
    private var contextMenu: PopoverMenu?
    private let bag = ObserverBag()
    private var nameColumn: ColumnViewColumn<BrowserEntry>!
    private var sizeColumn: ColumnViewColumn<BrowserEntry>!
    private var dateColumn: ColumnViewColumn<BrowserEntry>!
    private var isSyncing = false
    private var isApplyingSort = false
    /// Folders left with Back, for Forward (Core keeps only the back stack).
    private var forwardStack: [String] = []
    private var pendingHistoryMove: HistoryMove?
    private var lastLocation: String?
    private var paneActions: [String: SimpleAction] = [:]

    private enum HistoryMove { case back, forward }

    init(model: Model, kind: BrowserPaneKind, settings: AppSettings, actions: PaneActions,
         services: any WindowServices, accessory: Widget) {
        self.model = model
        self.kind = kind
        self.settings = settings
        self.actions = actions
        self.services = services
        columnView = ColumnView(store: store, selection: .multiple, sortsModel: false)
        gridView = GridView(store: store, factory: Self.makeGridFactory(), selection: .multiple)
        contentArea = Overlay()
        buildColumns()
        buildLayout(accessory: accessory)
        installActions()
        installBindings()
        installInput()
        if !model.hasLoaded {
            Task { await model.load() }
        }
    }

    // MARK: - Layout

    private func buildColumns() {
        let nameFactory = ListItemFactory<BrowserEntry, NameCell>(
            setup: { NameCell() },
            bind: { cell, entry, _ in
                cell.icon.setIconNames(EntryIcons.names(for: entry))
                cell.label.text = entry.name
                cell.root.setAssociated(EntryRef(entry), forKey: "art-entry")
            })
        let sizeFactory = ListItemFactory<BrowserEntry, Label>(
            setup: { Label().align(h: .end).css("numeric", "dim-label") },
            bind: { label, entry, _ in
                label.text = entry.isDirectory ? "—" : entry.formattedSize
                label.setAssociated(EntryRef(entry), forKey: "art-entry")
            })
        let dateFactory = ListItemFactory<BrowserEntry, Label>(
            setup: { Label().align(h: .start).css("numeric", "dim-label").then { $0.ellipsis = .end } },
            bind: { label, entry, _ in
                label.text = entry.formattedModifiedDate
                label.setAssociated(EntryRef(entry), forKey: "art-entry")
            })
        // Core sorts; the headers only report clicks (see onSortChanged).
        let unsorted = { Sorter<BrowserEntry> { _, _ in false } }
        nameColumn = ColumnViewColumn("Name", expand: true, sorter: unsorted(), factory: nameFactory)
        sizeColumn = ColumnViewColumn("Size", fixedWidth: 88, sorter: unsorted(), factory: sizeFactory)
        dateColumn = ColumnViewColumn("Modified", fixedWidth: 196, sorter: unsorted(), factory: dateFactory)
        columnView.append(nameColumn)
        columnView.append(sizeColumn)
        columnView.append(dateColumn)
        columnView.showsColumnSeparators = false
        columnView.css("data-table", "browser-list")
        gridView.maxColumns = 12
        gridView.minColumns = 2
        gridView.css("browser-grid")
    }

    private static func makeGridFactory() -> ListItemFactory<BrowserEntry, GridCell> {
        ListItemFactory(
            setup: { GridCell() },
            bind: { cell, entry, _ in
                cell.icon.setIconNames(EntryIcons.names(for: entry))
                cell.label.text = entry.name
                cell.root.tooltip = entry.name
                cell.root.setAssociated(EntryRef(entry), forKey: "art-entry")
            })
    }

    private func buildLayout(accessory: Widget) {
        root.css("browser-pane")
        root.insertActionGroup(actionGroup, prefix: "pane")

        // Row 1: the pane's identity (favourites / storage) and its actions.
        let header = Box(.horizontal, spacing: 6).css("pane-header")
        header.append(accessory)
        header.append(Box().expand(h: true))
        let spinner = Spinner().sizeRequest(width: 16, height: 16)
        let spinnerReveal = Revealer(spinner, transition: .crossfade, duration: Motion.Duration.quick)
        let model = model
        spinnerReveal.bind { $0.isRevealed = model.isLoading && model.hasLoaded }
        header.append(spinnerReveal)

        let refresh = Button(iconName: "view-refresh-symbolic", tooltip: "Refresh (Ctrl+R)").css("flat")
        refresh.actionName = "pane.refresh"
        let newFolder = Button(iconName: "folder-new-symbolic", tooltip: "New Folder (Ctrl+N)").css("flat")
        newFolder.actionName = "pane.new-folder"
        let hidden = ToggleButton(iconName: "view-reveal-symbolic", tooltip: "Show Hidden Files (Ctrl+H)").css("flat")
        hidden.bind { button in
            if button.isActive != model.showsHiddenFiles { button.isActive = model.showsHiddenFiles }
            button.isSensitive = !model.isLoading
        }
        hidden.onToggled { [weak self, weak hidden] in
            guard let self, let hidden, hidden.isActive != self.model.showsHiddenFiles else { return }
            self.toggleHiddenFiles()
        }
        let viewToggle = ToggleGroup().css("flat")
        viewToggle.add(name: BrowserViewMode.list.rawValue, iconName: "view-list-symbolic", tooltip: "List")
        viewToggle.add(name: BrowserViewMode.grid.rawValue, iconName: "view-grid-symbolic", tooltip: "Grid")
        viewToggle.bind { toggle in
            if toggle.activeName != model.viewMode.rawValue { toggle.activeName = model.viewMode.rawValue }
        }
        viewToggle.onActiveChanged { [weak self, weak viewToggle] in
            guard let self, let name = viewToggle?.activeName, let mode = BrowserViewMode(rawValue: name),
                  mode != self.model.viewMode else { return }
            self.setViewMode(mode)
        }
        let copy = Button(actions.copyTitle, iconName: actions.copyIcon).css("suggested-action", "copy-button")
        copy.tooltip = actions.copyTooltip
        copy.actionName = "pane.copy-to-other"
        header.append(hidden)
        header.append(viewToggle)
        header.append(Separator(.vertical).margins(top: 6, bottom: 6, start: 2, end: 2))
        header.append(copy)
        root.append(header)

        // Row 2: history buttons and the path bar.
        let pathRow = Box(.horizontal, spacing: 4).css("pane-toolbar")
        let navigation = Box(.horizontal, spacing: 0).css("linked")
        for (icon, action, tip) in [("go-previous-symbolic", "pane.back", "Back (Alt+Left)"),
                                    ("go-next-symbolic", "pane.forward", "Forward (Alt+Right)"),
                                    ("go-up-symbolic", "pane.up", "Enclosing Folder (Alt+Up)")] {
            let button = Button(iconName: icon, tooltip: tip)
            button.actionName = action
            navigation.append(button)
        }
        pathRow.append(navigation)
        breadcrumbBox.css("path-bar")
        breadcrumbBox.expand(h: true)
        pathRow.append(breadcrumbBox)
        let copying = Label("Copying…").css("dim-label", "caption")
        copying.tooltip = "Browsing the phone is paused until the current copy finishes."
        let copyingReveal = Revealer(copying, transition: .slideLeft, duration: Motion.Duration.standard)
        let actions = actions
        copyingReveal.bind { $0.isRevealed = actions.navigationDisabled() }
        pathRow.append(copyingReveal)
        let find = Button(iconName: "edit-find-symbolic", tooltip: "Filter This Folder (Ctrl+F)").css("flat")
        find.onClicked { [weak self] in
            guard let self else { return }
            if self.searchReveal.isRevealed { self.endSearch() } else { self.beginSearch() }
        }
        pathRow.append(find)
        pathRow.append(refresh)
        pathRow.append(newFolder)
        root.append(pathRow)

        // Filter-as-you-type (Ctrl+F).
        searchEntry.expand(h: true)
        searchReveal.child = Box(.horizontal, spacing: 0, [searchEntry]).css("pane-search")
        let search = search
        searchEntry.onSearchChanged { [weak self] in
            guard let self else { return }
            search.query = self.searchEntry.text
        }
        searchEntry.onStopSearch { [weak self] in self?.endSearch() }
        root.append(searchReveal)

        errorBanner.onButtonClicked { model.dismissError() }
        errorBanner.bind { banner in
            banner.title = model.error?.message ?? ""
            banner.isRevealed = model.error != nil
        }
        root.append(errorBanner)

        // Content.
        let listScroller = ScrolledWindow(columnView).expand(h: true, v: true)
        let gridScroller = ScrolledWindow(gridView).expand(h: true, v: true)
        contentStack.add(listScroller, name: "list")
        contentStack.add(gridScroller, name: "grid")
        let empty = StatusPage(title: actions.emptyTitle, description: actions.emptyMessage, iconName: "folder-symbolic")
        empty.css("compact", "empty-folder")
        contentStack.add(empty, name: "empty")
        let loading = StatusPage(title: "Opening Folder…", iconName: nil)
        loading.child = Spinner().sizeRequest(width: 32, height: 32)
        loading.css("compact")
        loading.bind { page in
            if let progress = model.loadingProgress {
                page.title = progress.folderName.map { "Opening “\($0)”…" } ?? "Opening Folder…"
                if let read = progress.itemsRead, let total = progress.itemCount {
                    page.descriptionText = "\(read.formatted()) of \(Format.count(total, "item"))"
                } else {
                    page.descriptionText = nil
                }
            } else {
                page.title = "Opening Folder…"
                page.descriptionText = nil
            }
        }
        contentStack.add(loading, name: "loading")
        let noResults = StatusPage(title: "No Results", iconName: "edit-find-symbolic").css("compact")
        noResults.bind { [search] page in page.descriptionText = "No items match “\(search.query)”." }
        contentStack.add(noResults, name: "no-results")
        contentStack.expand(h: true, v: true)
        contentArea.child = contentStack
        contentArea.css("pane-content")
        root.append(contentArea)

        // Status bar.
        let status = Box(.horizontal, spacing: 8).css("pane-status")
        let items = Label().css("dim-label", "caption", "numeric").align(h: .start)
        let capacityBar = LevelBar(offsets: [("normal", 0.9), ("nearly-full", 0.98), ("full", 1.0)])
            .sizeRequest(width: 64).align(v: .center)
        let capacity = Label().css("dim-label", "caption", "numeric")
        capacity.ellipsis = .middle
        status.append(items)
        status.append(Box().expand(h: true))
        status.append(capacityBar)
        status.append(capacity)
        status.bind { [settings] bar in bar.isVisible = settings.enableStatusBar }
        items.bind { label in
            let summary = StatusSummary(model: model)
            label.text = summary.itemsText + (summary.selectionText.map { " · \($0)" } ?? "")
        }
        capacity.bind { label in label.text = StatusSummary(model: model).capacityText }
        capacityBar.bind { bar in
            let fraction = StatusSummary(model: model).usedFraction
            bar.isVisible = fraction != nil
            bar.value = fraction ?? 0
        }
        root.append(status)
    }

    // MARK: - Bindings

    private func installBindings() {
        let model = model
        // Entries and selection, Core → views.
        root.bind { [weak self] _ in
            guard let self else { return }
            _ = model.entries
            _ = model.selectedEntryIDs
            _ = self.search.query
            self.applyEntries()
        }
        // Which page shows.
        contentStack.bind { [weak self] stack in
            guard let self else { return }
            let name: String
            if model.isLoading && (!model.hasLoaded || model.entries.isEmpty) {
                name = "loading"
            } else if model.hasLoaded && model.entries.isEmpty {
                name = "empty"
            } else if !self.search.query.isEmpty && model.filteredEntries(matching: self.search.query).isEmpty {
                name = "no-results"
            } else {
                name = model.viewMode == .grid ? "grid" : "list"
            }
            if stack.visibleChildName != name {
                let hadFocus = self.contentHasFocus
                stack.visibleChildName = name
                if hadFocus { self.focusContent() }
            }
        }
        // Breadcrumbs.
        breadcrumbBox.bind { [weak self] _ in
            guard let self else { return }
            self.rebuildBreadcrumbs(model.breadcrumbs, disabled: self.actions.navigationDisabled() || model.isLoading)
        }
        // Forward history follows location changes.
        bag.onChange({ model.currentLocation }) { [weak self] location in
            self?.locationChanged(to: location)
        }
        lastLocation = model.currentLocation
        // Sort indicator follows Core's sort.
        bag.onChange(initial: true, { model.sortDescriptor }) { [weak self] descriptor in
            self?.showSortIndicator(descriptor)
        }
        columnView.onSortChanged { [weak self] column, ascending in
            self?.headerSortChanged(column: column, ascending: ascending)
        }
        // Selection, views → Core.
        columnView.pipeline.selection.onSelectionChanged { [weak self] in
            guard let self else { return }
            self.viewSelectionChanged(self.columnView.pipeline)
        }
        gridView.pipeline.selection.onSelectionChanged { [weak self] in
            guard let self else { return }
            self.viewSelectionChanged(self.gridView.pipeline)
        }
        // Action sensitivity.
        root.bind { [weak self] _ in self?.updateActionStates() }
    }

    private var appliedQuery = ""

    private func applyEntries() {
        let entries = model.entries
        isSyncing = true
        if store.items != entries {
            store.replaceAll(entries)
        }
        let query = search.query
        if query != appliedQuery {
            appliedQuery = query
            let matches: (BrowserEntry) -> Bool = { query.isEmpty || $0.name.localizedStandardContains(query) }
            columnView.pipeline.filter.update(matches)
            gridView.pipeline.filter.update(matches)
        }
        isSyncing = false
        let ids = model.selectedEntryIDs
        for pipeline in [columnView.pipeline, gridView.pipeline] {
            let positions = Set((0..<pipeline.visibleCount).filter { pipeline.item(at: $0).map { ids.contains($0.id) } ?? false })
            if Set(pipeline.selection.selectedPositions) != positions {
                isSyncing = true
                pipeline.selection.setSelection(positions)
                isSyncing = false
            }
        }
    }

    func beginSearch() {
        searchReveal.isRevealed = true
        searchEntry.grabFocus()
    }

    func endSearch() {
        searchEntry.text = ""
        search.query = ""
        searchReveal.isRevealed = false
        focusContent()
    }

    private func viewSelectionChanged(_ pipeline: ListPipeline<BrowserEntry>) {
        guard !isSyncing else { return }
        let ids = Set(pipeline.selectedItems.map(\.id))
        if ids != model.selectedEntryIDs { model.selectedEntryIDs = ids }
    }

    private func rebuildBreadcrumbs(_ coreCrumbs: [BreadcrumbSegment], disabled: Bool) {
        breadcrumbBox.removeAllChildren()
        var crumbs = coreCrumbs
        var rootIcon = kind == .device ? "phone-symbolic" : "drive-harddisk-symbolic"
        if kind == .local {
            // Under the home folder the path starts at Home, as in Files.
            let home = XDGUserDirectories().home.standardizedFileURL.path
            if let homeIndex = crumbs.firstIndex(where: { $0.location == home }) {
                crumbs = [BreadcrumbSegment(id: home, label: "Home", location: home)] + crumbs[(homeIndex + 1)...]
                rootIcon = "user-home-symbolic"
            } else if let first = crumbs.first, first.location == "/" {
                crumbs[0] = BreadcrumbSegment(id: "/", label: "Computer", location: "/")
            }
        } else if let first = crumbs.first, let label = actions.rootLabel() {
            crumbs[0] = BreadcrumbSegment(id: first.id, label: label, location: first.location)
        }
        // Long paths keep the root and the last three folders.
        var hidden: BreadcrumbSegment?
        if crumbs.count > 5 {
            hidden = crumbs[crumbs.count - 4]
            crumbs = [crumbs[0]] + crumbs.suffix(3)
        }
        for (index, crumb) in crumbs.enumerated() {
            if index > 0 {
                breadcrumbBox.append(Label("/").css("dim-label", "path-separator"))
            }
            if index == 1, let hidden {
                let more = Button("…").css("flat", "path-crumb")
                more.tooltip = hidden.location
                more.isSensitive = !disabled
                more.onClicked { [weak self] in self?.navigate(to: hidden) }
                breadcrumbBox.append(more)
                breadcrumbBox.append(Label("/").css("dim-label", "path-separator"))
            }
            let isLast = index == crumbs.count - 1
            let label = Label(crumb.label)
            if crumb.label.count > 22 || isLast {
                label.ellipsis = .middle
                label.maxWidthChars = isLast ? 32 : 22
            }
            let child: Widget = index == 0 ? Box(.horizontal, spacing: 6, [Image(iconName: rootIcon), label]) : label
            let button = Button(child: child).css("flat", "path-crumb")
            if isLast { button.addCSSClass("current") }
            button.tooltip = crumb.location
            button.isSensitive = !disabled
            button.onClicked { [weak self] in self?.navigate(to: crumb) }
            breadcrumbBox.append(button)
        }
    }

    private func updateActionStates() {
        let busy = model.isLoading
        let navDisabled = actions.navigationDisabled()
        let opsDisabled = navDisabled || model.fileOperationsDisabled || busy
        let selection = model.selectedEntryIDs
        let selected = model.selectedEntries
        setEnabled("back", model.canGoBack && !busy && !navDisabled)
        setEnabled("forward", !forwardStack.isEmpty && !busy && !navDisabled)
        setEnabled("up", model.canGoUp && !busy && !navDisabled)
        setEnabled("refresh", !busy && !navDisabled)
        setEnabled("new-folder", !opsDisabled)
        setEnabled("rename", !opsDisabled && selection.count == 1)
        setEnabled("delete", !opsDisabled && !selection.isEmpty)
        setEnabled("copy-to-other", !selection.isEmpty && actions.canCopyToOther())
        setEnabled("add-to-queue", !opsDisabled && !selection.isEmpty && actions.canAddToQueue())
        setEnabled("copy", !opsDisabled && !selection.isEmpty && actions.canClipboardCopy())
        setEnabled("paste", !opsDisabled && actions.canPaste())
        setEnabled("open", selected.count == 1 && !navDisabled)
        setEnabled("copy-path", !selection.isEmpty)
        setEnabled("info", selection.count == 1)
        setEnabled("show-in-files", kind == .local && !selection.isEmpty)
        setEnabled("date-range", actions.dateRange != nil && actions.canDateRange() && selected.contains(where: \.isDirectory))
        setEnabled("toggle-hidden", !busy && !navDisabled)
    }

    private func setEnabled(_ name: String, _ enabled: Bool) {
        if let action = paneActions[name], action.isEnabled != enabled { action.isEnabled = enabled }
    }

    // MARK: - Actions

    private func installActions() {
        func add(_ name: String, _ body: @escaping @MainActor (BrowserPane) -> Void) {
            let action = SimpleAction(name) { [weak self] in
                guard let self else { return }
                body(self)
            }
            actionGroup.add(action)
            paneActions[name] = action
        }
        add("back") { $0.goBack() }
        add("forward") { $0.goForward() }
        add("up") { $0.goUp() }
        add("refresh") { $0.refresh() }
        add("new-folder") { $0.presentNewFolder() }
        add("rename") { $0.presentRename() }
        add("delete") { $0.presentDelete() }
        add("copy-to-other") { pane in
            guard pane.paneActions["copy-to-other"]?.isEnabled == true else { return }
            pane.actions.copyToOther()
        }
        add("add-to-queue") { pane in
            pane.actions.addToQueue()
            pane.services?.toast("Added to the copy queue")
        }
        add("copy") { pane in
            let count = pane.model.selectedEntryIDs.count
            pane.actions.clipboardCopy()
            pane.services?.toast("\(Format.count(count, "item")) ready to paste into the other pane")
        }
        add("paste") { $0.actions.paste() }
        add("open") { $0.openSelection() }
        add("copy-path") { pane in
            let paths = pane.model.copyablePaths(for: pane.model.selectedEntryIDs)
            Clipboard.setText(paths.joined(separator: "\n"))
            pane.services?.toast(paths.count == 1 ? "Path copied" : "\(paths.count) paths copied")
        }
        add("info") { $0.presentInfo() }
        add("show-in-files") { pane in
            let urls = pane.model.revealableURLs(for: pane.model.selectedEntryIDs)
            if let first = urls.first { Launcher.showInFileManager(path: first.path, parent: pane.services?.window) }
        }
        add("date-range") { $0.actions.dateRange?() }
        add("select-all") { pane in pane.model.selectAll() }
        add("toggle-hidden") { $0.toggleHiddenFiles() }
    }

    func refresh() {
        guard !model.isLoading, !actions.navigationDisabled() else { return }
        Task { await model.refresh() }
    }

    func goUp() {
        guard model.canGoUp, !model.isLoading, !actions.navigationDisabled() else { return }
        Task { await model.goUp() }
    }

    func goBack() {
        guard model.canGoBack, !model.isLoading, !actions.navigationDisabled() else { return }
        pendingHistoryMove = .back
        Task { await model.goBack() }
    }

    func goForward() {
        guard let destination = forwardStack.last, !model.isLoading, !actions.navigationDisabled() else { return }
        pendingHistoryMove = .forward
        Task {
            await model.navigate(to: BreadcrumbSegment(id: destination, label: destination, location: destination))
        }
    }

    private func navigate(to crumb: BreadcrumbSegment) {
        guard !model.isLoading, !actions.navigationDisabled() else { return }
        Task { await model.navigate(to: crumb) }
    }

    private func locationChanged(to location: String) {
        if !search.query.isEmpty || searchReveal.isRevealed {
            searchEntry.text = ""
            search.query = ""
            searchReveal.isRevealed = false
        }
        defer {
            lastLocation = location
            pendingHistoryMove = nil
            updateActionStates()
        }
        switch pendingHistoryMove {
        case .back:
            if let lastLocation { forwardStack.append(lastLocation) }
        case .forward:
            if forwardStack.last == location { forwardStack.removeLast() } else { forwardStack.removeAll() }
        case nil:
            forwardStack.removeAll()
        }
    }

    func activate(_ entry: BrowserEntry) {
        guard !actions.navigationDisabled() || !entry.isDirectory else { return }
        Task { await model.openEntry(entry) }
    }

    private func openSelection() {
        guard let entry = model.selectedEntries.first, model.selectedEntries.count == 1 else { return }
        activate(entry)
    }

    func setViewMode(_ mode: BrowserViewMode) {
        let hadFocus = contentHasFocus
        model.viewMode = mode
        switch kind {
        case .local: settings.localViewMode = mode
        case .device: settings.deviceViewMode = mode
        }
        if hadFocus { focusContent() }
    }

    func toggleHiddenFiles() {
        guard !model.isLoading, !actions.navigationDisabled() else { return }
        let show = !model.showsHiddenFiles
        Task {
            await model.setShowsHiddenFiles(show)
            switch kind {
            case .local: settings.localShowsHiddenFiles = show
            case .device: settings.deviceShowsHiddenFiles = show
            }
        }
    }

    // MARK: - Sorting

    private func showSortIndicator(_ descriptor: BrowserSortDescriptor) {
        let column: ColumnViewColumn<BrowserEntry> = switch descriptor.column {
        case .name: nameColumn
        case .size: sizeColumn
        case .modified: dateColumn
        }
        isApplyingSort = true
        columnView.sort(by: column, ascending: descriptor.direction == .ascending)
        isApplyingSort = false
    }

    private func headerSortChanged(column: ColumnViewColumn<BrowserEntry>?, ascending: Bool) {
        guard !isApplyingSort, let column else { return }
        let target: BrowserSortColumn = column === sizeColumn ? .size : column === dateColumn ? .modified : .name
        let direction: BrowserSortDirection = ascending ? .ascending : .descending
        var guardCount = 0
        while model.sortDescriptor != BrowserSortDescriptor(column: target, direction: direction), guardCount < 3 {
            model.toggleSort(target)
            guardCount += 1
        }
    }

    /// The page the content area shows (tests).
    var contentStackPage: String { contentStack.visibleChildName ?? "" }

    // MARK: - Focus

    var contentHasFocus: Bool {
        columnView.containsFocus || gridView.containsFocus
    }

    func focusContent() {
        if model.viewMode == .grid {
            gridView.grabFocus()
        } else {
            columnView.grabFocus()
        }
    }

    // MARK: - Input

    private func installInput() {
        columnView.onActivate { [weak self] entry, _ in self?.activate(entry) }
        gridView.onActivate { [weak self] entry, _ in self?.activate(entry) }

        let keys = ShortcutController(scope: .local)
        keys.add("Delete|KP_Delete|<Shift>Delete") { [weak self] in self?.activateIfEnabled("delete") ?? false }
        keys.add("F2|<Control>d") { [weak self] in self?.activateIfEnabled("rename") ?? false }
        keys.add("<Control>c") { [weak self] in self?.activateIfEnabled("copy") ?? false }
        keys.add("<Control><Shift>c") { [weak self] in self?.activateIfEnabled("add-to-queue") ?? false }
        keys.add("<Control>v") { [weak self] in self?.activateIfEnabled("paste") ?? false }
        keys.add("<Alt>Up|<Control>b") { [weak self] in self?.activateIfEnabled("up") ?? false }
        keys.add("<Alt>Left|BackSpace") { [weak self] in self?.activateIfEnabled("back") ?? false }
        keys.add("<Alt>Right") { [weak self] in self?.activateIfEnabled("forward") ?? false }
        keys.add("<Control>h") { [weak self] in self?.activateIfEnabled("toggle-hidden") ?? false }
        keys.add("<Control>i|<Alt>Return") { [weak self] in self?.activateIfEnabled("info") ?? false }
        keys.add("<Control>a") { [weak self] in
            self?.model.selectAll()
            return true
        }
        keys.add("<Control>f") { [weak self] in
            self?.beginSearch()
            return true
        }
        keys.add("Escape") { [weak self] in
            guard let self, !self.model.selectedEntryIDs.isEmpty else { return false }
            self.model.clearSelection()
            return true
        }
        root.add(keys)

        let focus = FocusController()
        focus.onEnter { [weak self] in
            guard let self else { return }
            self.services?.paneDidFocus(self.kind)
        }
        root.add(focus)
        let click = ClickGesture(button: 0)
        click.phase = .capture
        click.onPressed { [weak self] _, _, _ in
            guard let self else { return }
            self.services?.paneDidFocus(self.kind)
        }
        root.add(click)

        // Context menu.
        let menu = Menu()
        menu.appendSection(Menu().appending("Open", action: "pane.open"))
        let transfer = Menu()
        transfer.append(actions.copyTitle, action: "pane.copy-to-other")
        transfer.append("Add to Copy Queue", action: "pane.add-to-queue")
        transfer.append("Copy", action: "pane.copy")
        transfer.append("Paste", action: "pane.paste")
        if actions.dateRange != nil { transfer.append("Copy by Date Range…", action: "pane.date-range") }
        menu.appendSection(transfer)
        let files = Menu()
        files.append("New Folder…", action: "pane.new-folder")
        files.append("Rename…", action: "pane.rename")
        files.append(actions.trashLabel, action: "pane.delete")
        menu.appendSection(files)
        let more = Menu()
        if kind == .local { more.append("Show in Files", action: "pane.show-in-files") }
        more.append("Copy Path", action: "pane.copy-path")
        more.append("Properties", action: "pane.info")
        menu.appendSection(more)
        let popover = PopoverMenu(menu: menu, parent: contentArea)
        contextMenu = popover
        let secondary = ClickGesture(button: 3)
        secondary.onPressed { [weak self] _, x, y in self?.showContextMenu(x: x, y: y) }
        contentArea.add(secondary)
        let longPress = ShortcutController(scope: .local)
        longPress.add("<Shift>F10|Menu") { [weak self] in
            guard let self else { return false }
            self.showContextMenu(x: Double(self.contentArea.width) / 2, y: 40)
            return true
        }
        contentArea.add(longPress)
    }

    private func activateIfEnabled(_ name: String) -> Bool {
        guard let action = paneActions[name] else { return false }
        if action.isEnabled { action.activate() }
        return true
    }

    /// The entry drawn at (`x`, `y`) of the content area, if any.
    func entry(atX x: Double, y: Double) -> BrowserEntry? {
        let picked = contentArea.pick(x: x, y: y)
        return (Widget.nearestAssociated(from: picked, forKey: "art-entry") as? EntryRef)?.entry
    }

    /// What a drag or right-click at (`x`, `y`) acts on: the whole selection
    /// when the entry there is selected, else just that entry.
    func targetEntries(atX x: Double, y: Double) -> [BrowserEntry] {
        guard let entry = entry(atX: x, y: y) else { return [] }
        if model.selectedEntryIDs.contains(entry.id) { return model.selectedEntries }
        return [entry]
    }

    private func showContextMenu(x: Double, y: Double) {
        services?.paneDidFocus(kind)
        if let entry = entry(atX: x, y: y) {
            if !model.selectedEntryIDs.contains(entry.id) { model.selectedEntryIDs = [entry.id] }
        } else {
            model.clearSelection()
        }
        updateActionStates()
        contextMenu?.popup(at: x, y: y)
    }

    // MARK: - Prompts

    private var parentWindow: Window? { services?.window }

    func presentNewFolder() {
        presentNamePrompt(entry: nil)
    }

    func presentRename() {
        guard model.selectedEntries.count == 1, let entry = model.selectedEntries.first else { return }
        presentNamePrompt(entry: entry)
    }

    private func presentNamePrompt(entry: BrowserEntry?) {
        let isRename = entry != nil
        let hint = isRename ? "Enter a new name." : (kind == .device ? "The folder is created on the phone." : "The folder is created here.")
        let alert = AlertDialog(heading: isRename ? "Rename “\(entry!.name)”" : "New Folder", body: hint)
        let field = Entry(text: entry?.name ?? model.suggestedNewFolderName())
        field.setProperty("activates-default", true)
        alert.extraChild = field
        alert.addResponse("cancel", "Cancel")
        alert.addResponse("save", isRename ? "Rename" : "Create", appearance: .suggested)
        alert.defaultResponse = "save"
        alert.closeResponse = "cancel"
        let model = model
        let validate: @MainActor () -> Void = { [weak alert, weak field] in
            guard let alert, let field else { return }
            let message = model.nameValidationMessage(field.text, renaming: entry)
            alert.setResponseEnabled("save", message == nil && field.text != entry?.name)
            alert.body = message ?? hint
        }
        field.onChanged(validate)
        validate()
        Task { [weak self] in
            let response = await alert.choose(parent: self?.parentWindow)
            guard response == "save", let self else { return }
            let name = field.text
            guard model.nameValidationMessage(name, renaming: entry) == nil else { return }
            let succeeded = isRename ? await model.renameSelectedEntry(to: name) : await model.makeDirectory(named: name)
            if succeeded { self.highlight(named: name) }
        }
        // Select the name without its extension, like the file manager.
        if let entry, !entry.isDirectory, let dot = entry.name.lastIndex(of: "."), dot != entry.name.startIndex {
            let length = entry.name.distance(from: entry.name.startIndex, to: dot)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak field] in
                MainActor.assumeIsolated { field?.selectRegion(start: 0, end: length) }
            }
        }
    }

    /// Selects the item now called `name` and scrolls it into view.
    private func highlight(named name: String) {
        guard let entry = model.entries.first(where: { $0.name == name }) else { return }
        model.selectedEntryIDs = [entry.id]
        if let index = store.items.firstIndex(where: { $0.id == entry.id }) {
            if model.viewMode == .grid { gridView.scrollTo(index, focus: true) } else { columnView.scrollTo(index, focus: true) }
        }
    }

    func presentDelete() {
        guard let confirmation = model.deletionConfirmation() else { return }
        let alert = AlertDialog(heading: confirmation.title, body: confirmation.message)
        alert.addResponse("cancel", "Cancel")
        let isTrash = confirmation.destination == .trash
        alert.addResponse("delete", isTrash ? "Move to Trash" : "Delete", appearance: .destructive)
        alert.defaultResponse = isTrash ? "delete" : "cancel"
        alert.closeResponse = "cancel"
        let model = model
        Task { [weak self] in
            guard await alert.choose(parent: self?.parentWindow) == "delete" else { return }
            let count = confirmation.names.count
            if await model.deleteSelectedEntries() {
                self?.services?.toast(isTrash
                    ? "\(Format.count(count, "item")) moved to the Trash"
                    : "\(Format.count(count, "item")) deleted from the phone")
            }
        }
    }

    func presentInfo() {
        guard model.selectedEntries.count == 1, let entry = model.selectedEntries.first else { return }
        let dialog = Dialog(title: "Properties", width: 420)
        let toolbar = ToolbarView()
        toolbar.addTopBar(HeaderBar())
        let icon = Image(iconName: "text-x-generic", pixelSize: 64)
        icon.setIconNames(EntryIcons.names(for: entry))
        let title = Label(entry.name).css("title-3")
        title.wraps = true
        title.justifyCenter = true
        title.isSelectable = true
        let list = ListBox()
        func row(_ name: String, _ value: String) {
            let row = ActionRow(title: name, subtitle: value)
            row.css("property")
            row.setProperty("subtitle-selectable", true)
            list.append(row)
        }
        row("Kind", EntryIcons.typeDescription(for: entry))
        if !entry.isDirectory { row("Size", entry.size.map { "\(Format.bytes($0)) (\($0.formatted()) bytes)" } ?? "Unknown") }
        row("Modified", entry.modified.map { $0.formatted(date: .long, time: .standard) } ?? "Unknown")
        row(kind == .device ? "Location on the phone" : "Location", (entry.location as NSString).deletingLastPathComponent)
        let content = Box(.vertical, spacing: 12, [icon, title, list]).margins(top: 12, bottom: 24, start: 24, end: 24)
        toolbar.content = content
        dialog.child = toolbar
        dialog.present(parent: parentWindow)
    }
}

/// Browser status bar wording (items, selection and free space).
@MainActor
struct StatusSummary {
    let itemCount: Int
    let selectedCount: Int
    let selectedBytes: Int64?
    let capacity: BrowserCapacity?

    init(model: some BrowserPaneModel) {
        itemCount = model.entries.count
        let selected = model.selectedEntries
        selectedCount = selected.count
        let sizes = selected.compactMap(\.size)
        selectedBytes = sizes.isEmpty ? nil : sizes.reduce(0, +)
        capacity = model.capacity
    }

    var itemsText: String { Format.count(itemCount, "item") }

    var selectionText: String? {
        guard selectedCount > 0 else { return nil }
        let count = "\(selectedCount.formatted()) selected"
        guard let selectedBytes else { return count }
        return "\(count) (\(Format.bytes(selectedBytes)))"
    }

    var capacityText: String {
        guard let capacity else { return "Free space unavailable" }
        return "\(capacity.formattedFreeBytes) free of \(capacity.formattedTotalBytes)"
    }

    var usedFraction: Double? {
        guard let capacity, capacity.totalBytes > 0 else { return nil }
        let used = Double(capacity.totalBytes - capacity.freeBytes) / Double(capacity.totalBytes)
        return min(max(used, 0), 1)
    }
}
