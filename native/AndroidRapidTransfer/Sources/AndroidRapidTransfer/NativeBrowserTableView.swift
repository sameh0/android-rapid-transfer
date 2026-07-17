import AppKit
import AndroidRapidTransferCore
import SwiftUI

struct NativeBrowserTableView<Model: BrowserPaneModel>: NSViewRepresentable {
    @Bindable var model: Model
    let entries: [BrowserEntry]
    /// The folder listed; a change is a navigation, not an edit of the rows.
    let location: String
    /// Whether same-folder row changes may animate (small lists, motion on).
    let animatesChanges: Bool
    let highlight: BrowserEntryHighlight?
    let navigationDisabled: Bool
    let filePromiseExporter: ((BrowserEntry, URL) async throws -> Void)?
    let dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
    let copyAction: BrowserCopyAction?
    let queueAction: BrowserCopyAction?
    let dateRangeAction: BrowserCopyAction?
    let paneKind: BrowserPaneKind
    let focusCoordinator: PaneFocusCoordinator
    let createFolder: () -> Void
    let rename: (Set<BrowserEntry.ID>) -> Void
    let delete: (Set<BrowserEntry.ID>) -> Void
    let showInfo: (Set<BrowserEntry.ID>) -> Void
    var clipboard: BrowserClipboardCommands = .unavailable

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = BrowserNSTableView()
        context.coordinator.configure(tableView)

        tableView.frame = scrollView.contentView.bounds
        tableView.autoresizingMask = [.width]
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder

        context.coordinator.tableView = tableView
        context.coordinator.entries = entries
        context.coordinator.location = location
        // A highlight from before this table existed (e.g. made in grid view)
        // has already been shown.
        context.coordinator.markHighlightShown(highlight)
        context.coordinator.seedSortDescriptors()
        context.coordinator.reloadDataPreservingSelection()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let isNavigation = coordinator.location != location
        coordinator.location = location
        if coordinator.entries != entries {
            coordinator.apply(entries, animated: animatesChanges && !isNavigation)
            if isNavigation {
                coordinator.scrollToTop()
            }
        } else {
            coordinator.reconcileSelection()
        }
        coordinator.popHighlightIfNeeded(highlight)
        coordinator.applyFocusRequestIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeBrowserTableView
        var entries: [BrowserEntry] = []
        var location = ""
        weak var tableView: BrowserNSTableView?
        private var lastPoppedHighlight: BrowserEntryHighlight?

        private var isApplyingSelection = false
        private var isSeedingSortDescriptors = false
        private var lastAppliedFocusRevision: Int?
        private var contextSelection: Set<BrowserEntry.ID> = []

        init(parent: NativeBrowserTableView) {
            self.parent = parent
        }

        func configure(_ tableView: BrowserNSTableView) {
            tableView.dataSource = self
            tableView.delegate = self
            tableView.allowsMultipleSelection = true
            tableView.allowsEmptySelection = true
            tableView.allowsColumnReordering = false
            tableView.allowsColumnResizing = true
            tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            tableView.selectionHighlightStyle = .regular
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.rowSizeStyle = .default
            tableView.target = self
            tableView.doubleAction = #selector(openDoubleClickedRow)
            tableView.focusHandler = { [weak self] in self?.tableDidFocus() }
            tableView.contextMenuProvider = { [weak self] event in
                self?.contextMenu(for: event)
            }
            tableView.keyEventHandler = { [weak self] event in
                self?.handleKeyEvent(event) ?? false
            }
            // The standard Edit ▸ Copy/Paste items reach these through the
            // responder chain while the table is focused, so ⌘C/⌘V act on the
            // browser here and keep their text meaning in text fields.
            tableView.canCopySelection = { [weak self] in
                guard let self else { return false }
                return self.parent.clipboard.isCopyAvailable
                    && !self.parent.model.selectedEntryIDs.isEmpty
            }
            tableView.copySelection = { [weak self] in self?.parent.clipboard.copy() }
            tableView.canPasteQueue = { [weak self] in self?.parent.clipboard.canPaste ?? false }
            tableView.pasteQueue = { [weak self] in self?.parent.clipboard.paste() }
            tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
            tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

            for columnKind in NativeBrowserTableColumn.allCases {
                let column = NSTableColumn(identifier: columnKind.identifier)
                column.title = columnKind.title
                column.minWidth = columnKind.minimumWidth
                column.width = columnKind.idealWidth
                column.maxWidth = columnKind.maximumWidth
                column.sortDescriptorPrototype = columnKind.sortDescriptor(ascending: true)
                tableView.addTableColumn(column)
            }
        }

        func seedSortDescriptors() {
            isSeedingSortDescriptors = true
            defer { isSeedingSortDescriptors = false }
            tableView?.sortDescriptors = NativeBrowserTableMapping.sortDescriptors(
                for: parent.model.tableSortOrder
            )
        }

        func reconcileSelection() {
            guard let tableView else { return }
            let desiredRows = NativeBrowserTableMapping.rowIndexes(
                for: parent.model.selectedEntryIDs,
                in: entries
            )
            guard tableView.selectedRowIndexes != desiredRows else { return }

            isApplyingSelection = true
            defer { isApplyingSelection = false }
            tableView.selectRowIndexes(desiredRows, byExtendingSelection: false)
        }

        func reloadDataPreservingSelection() {
            guard let tableView else { return }
            // AppKit retains selected row indexes across reloads and may notify
            // the delegate before selection is restored by entry identity.
            isApplyingSelection = true
            tableView.reloadData()
            isApplyingSelection = false
            reconcileSelection()
        }

        /// Swaps in `newEntries`. Animated, rows fade out, slide in and move
        /// to their new place (a delete, a new folder, a re-sort); otherwise,
        /// or when the change is too big or tangled to animate, it reloads.
        func apply(_ newEntries: [BrowserEntry], animated: Bool) {
            let oldEntries = entries
            entries = newEntries
            guard animated, let tableView else {
                reloadDataPreservingSelection()
                return
            }
            let update = NativeBrowserTableMapping.rowUpdate(
                from: oldEntries.map(\.id),
                to: newEntries.map(\.id),
                maxAnimatedRows: BrowserListingAnimation.maxAnimatedItems
            )
            isApplyingSelection = true
            switch update {
            case .unchanged:
                break
            case .reload:
                tableView.reloadData()
            case let .insertRemove(removed, inserted):
                tableView.beginUpdates()
                tableView.removeRows(at: removed, withAnimation: [.effectFade, .slideUp])
                tableView.insertRows(at: inserted, withAnimation: [.effectFade, .slideDown])
                tableView.endUpdates()
            case let .reorder(moves):
                tableView.beginUpdates()
                for move in moves {
                    tableView.moveRow(at: move.from, to: move.to)
                }
                tableView.endUpdates()
            }
            if update != .reload {
                let changedRows = NativeBrowserTableMapping.rowsWithChangedContent(
                    from: oldEntries,
                    to: newEntries
                )
                if !changedRows.isEmpty {
                    tableView.reloadData(
                        forRowIndexes: changedRows,
                        columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
                    )
                }
            }
            isApplyingSelection = false
            reconcileSelection()
        }

        func scrollToTop() {
            guard let tableView, tableView.numberOfRows > 0 else { return }
            tableView.scrollRowToVisible(0)
        }

        func markHighlightShown(_ highlight: BrowserEntryHighlight?) {
            lastPoppedHighlight = highlight
        }

        /// Brings a just-created or just-renamed item into view and pops its
        /// icon, once per highlight.
        func popHighlightIfNeeded(_ highlight: BrowserEntryHighlight?) {
            guard let highlight, highlight != lastPoppedHighlight, let tableView,
                  let row = entries.firstIndex(where: { $0.id == highlight.entryID }) else { return }
            lastPoppedHighlight = highlight
            tableView.scrollRowToVisible(row)
            guard !MotionPolicy.current.reduceMotion,
                  let nameColumn = tableView.tableColumns.firstIndex(where: {
                      $0.identifier == NativeBrowserTableColumn.name.identifier
                  }),
                  let cell = tableView.view(
                      atColumn: nameColumn,
                      row: row,
                      makeIfNecessary: false
                  ) as? BrowserTableCellView else { return }
            cell.popIcon()
        }

        func applyFocusRequestIfNeeded() {
            let revision = parent.focusCoordinator.requestRevision
            guard parent.focusCoordinator.requestedPane == parent.paneKind,
                  lastAppliedFocusRevision != revision else { return }
            lastAppliedFocusRevision = revision
            tableView?.requestFirstResponder()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard entries.indices.contains(row),
                  let tableColumn,
                  let columnKind = NativeBrowserTableColumn(identifier: tableColumn.identifier)
            else { return nil }

            let entry = entries[row]
            let cell = reusableCell(for: columnKind, in: tableView)
            cell.configure(with: entry, column: columnKind)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            parent.model.selectedEntryIDs = NativeBrowserTableMapping.entryIDs(
                at: tableView.selectedRowIndexes,
                in: entries
            )
        }

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !isSeedingSortDescriptors else { return }
            let comparators = NativeBrowserTableMapping.comparators(
                for: tableView.sortDescriptors
            )
            guard !comparators.isEmpty else { return }
            parent.model.tableSortOrder = comparators
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> (any NSPasteboardWriting)? {
            guard entries.indices.contains(row) else { return nil }

            if let dragWriter = parent.dragWriter {
                // The dual-pane writer already contains the entire selection.
                // Returning it once keeps the pasteboard payload aggregated.
                guard row == tableView.selectedRowIndexes.first else { return nil }
                return dragWriter(entries[row])
            }

            guard let exporter = parent.filePromiseExporter else { return nil }
            return DeviceFilePromiseDelegate(
                entry: entries[row],
                exporter: exporter
            ).makeProvider()
        }

        func tableView(
            _ tableView: NSTableView,
            typeSelectStringFor tableColumn: NSTableColumn?,
            row: Int
        ) -> String? {
            guard entries.indices.contains(row) else { return nil }
            return entries[row].name
        }

        @objc private func openDoubleClickedRow() {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            openSelection()
        }

        private func reusableCell(
            for column: NativeBrowserTableColumn,
            in tableView: NSTableView
        ) -> BrowserTableCellView {
            if let cell = tableView.makeView(
                withIdentifier: column.cellIdentifier,
                owner: nil
            ) as? BrowserTableCellView {
                return cell
            }
            return BrowserTableCellView(column: column)
        }

        private func tableDidFocus() {
            parent.focusCoordinator.paneDidFocus(parent.paneKind)
        }

        private func handleKeyEvent(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([
                .command, .shift, .option, .control
            ])

            if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
                openSelection()
                return true
            }
            if modifiers == .command, event.keyCode == 125 {
                openSelection()
                return true
            }
            if modifiers == .command, event.keyCode == 126 {
                goUp()
                return true
            }
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "b" {
                goUp()
                return true
            }
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "d" {
                renameSelection()
                return true
            }
            if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
                deleteSelection()
                return true
            }
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "a" {
                tableView?.selectAll(nil)
                return true
            }
            // Fallback for when the Edit menu did not claim the key equivalent.
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                tableView?.copy(nil)
                return true
            }
            if modifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                tableView?.paste(nil)
                return true
            }
            if modifiers.isEmpty, event.keyCode == 53 {
                tableView?.deselectAll(nil)
                return true
            }
            return false
        }

        private func openSelection() {
            guard !parent.navigationDisabled, !parent.model.isLoading else { return }
            Task { await parent.model.openSelection() }
        }

        private func goUp() {
            guard !parent.navigationDisabled,
                  !parent.model.isLoading,
                  parent.model.canGoUp else { return }
            Task { await parent.model.goUp() }
        }

        private func renameSelection() {
            guard !operationsDisabled else { return }
            parent.rename(parent.model.selectedEntryIDs)
        }

        private func deleteSelection() {
            guard !operationsDisabled else { return }
            parent.delete(parent.model.selectedEntryIDs)
        }

        private var operationsDisabled: Bool {
            parent.navigationDisabled
                || parent.model.fileOperationsDisabled
                || parent.model.isLoading
        }

        private func contextMenu(for event: NSEvent) -> NSMenu? {
            guard let tableView else { return nil }
            tableView.requestFirstResponder()
            tableDidFocus()

            let point = tableView.convert(event.locationInWindow, from: nil)
            let clickedRow = tableView.row(at: point)
            if clickedRow >= 0, !tableView.selectedRowIndexes.contains(clickedRow) {
                tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }

            contextSelection = NativeBrowserTableMapping.entryIDs(
                at: tableView.selectedRowIndexes,
                in: entries
            )

            if #available(macOS 14.4, *) {
                return NSHostingMenu(
                    rootView: BrowserEntryContextMenu(
                        model: parent.model,
                        selection: contextSelection,
                        copyAction: parent.copyAction,
                        queueAction: parent.queueAction,
                        dateRangeAction: parent.dateRangeAction,
                        operationsDisabled: operationsDisabled,
                        createFolder: parent.createFolder,
                        rename: parent.rename,
                        delete: parent.delete,
                        showInfo: parent.showInfo,
                        clipboard: parent.clipboard
                    )
                )
            }
            return fallbackContextMenu()
        }

        private func fallbackContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(menuItem(
                title: "New Folder",
                systemImage: "folder.badge.plus",
                action: #selector(createFolderFromMenu),
                enabled: !operationsDisabled
            ))
            menu.addItem(menuItem(
                title: "Rename",
                systemImage: "pencil",
                action: #selector(renameFromMenu),
                enabled: !operationsDisabled && contextSelection.count == 1
            ))
            menu.addItem(menuItem(
                title: "Delete",
                systemImage: "trash",
                action: #selector(deleteFromMenu),
                enabled: !operationsDisabled && !contextSelection.isEmpty
            ))

            if parent.copyAction != nil || parent.queueAction != nil || parent.dateRangeAction != nil {
                menu.addItem(.separator())
            }
            if let copyAction = parent.copyAction {
                menu.addItem(menuItem(
                    title: copyAction.title,
                    systemImage: copyAction.systemImage,
                    action: #selector(copyFromMenu),
                    enabled: !operationsDisabled
                        && !contextSelection.isEmpty
                        && copyAction.isEnabled
                ))
            }
            if let queueAction = parent.queueAction {
                menu.addItem(menuItem(
                    title: queueAction.title,
                    systemImage: queueAction.systemImage,
                    action: #selector(addToQueueFromMenu),
                    enabled: !operationsDisabled
                        && !contextSelection.isEmpty
                        && queueAction.isEnabled
                ))
            }

            if let dateRangeAction = parent.dateRangeAction {
                menu.addItem(menuItem(
                    title: dateRangeAction.title,
                    systemImage: dateRangeAction.systemImage,
                    action: #selector(copyByDateRangeFromMenu),
                    enabled: !operationsDisabled
                        && dateRangeAction.isEnabled
                        && contextSelectionHasFolder
                ))
            }

            menu.addItem(.separator())
            if parent.model.supportsRevealInFinder {
                menu.addItem(menuItem(
                    title: "Show in Finder",
                    systemImage: "finder",
                    action: #selector(revealInFinderFromMenu),
                    enabled: !contextSelection.isEmpty
                ))
            }
            menu.addItem(menuItem(
                title: "Copy Path",
                systemImage: "doc.on.clipboard",
                action: #selector(copyPathFromMenu),
                enabled: !contextSelection.isEmpty
            ))
            menu.addItem(menuItem(
                title: "Get Info",
                systemImage: "info.circle",
                action: #selector(showInfoFromMenu),
                enabled: contextSelection.count == 1
            ))
            return menu
        }

        private func menuItem(
            title: String,
            systemImage: String,
            action: Selector,
            enabled: Bool
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
            item.isEnabled = enabled
            return item
        }

        @objc private func createFolderFromMenu() {
            parent.createFolder()
        }

        @objc private func renameFromMenu() {
            parent.rename(contextSelection)
        }

        @objc private func deleteFromMenu() {
            parent.delete(contextSelection)
        }

        @objc private func copyFromMenu() {
            parent.model.selectedEntryIDs = contextSelection
            parent.copyAction?.perform()
        }


        @objc private func addToQueueFromMenu() {
            parent.model.selectedEntryIDs = contextSelection
            parent.queueAction?.perform()
        }

        @objc private func copyByDateRangeFromMenu() {
            parent.model.selectedEntryIDs = contextSelection
            parent.dateRangeAction?.perform()
        }

        /// Mirrors ``BrowserEntryContextMenu``: the date-range scan needs at
        /// least one folder in the row set that was actually right-clicked.
        private var contextSelectionHasFolder: Bool {
            parent.model.entries.contains {
                $0.isDirectory && contextSelection.contains($0.id)
            }
        }

        @objc private func showInfoFromMenu() {
            parent.showInfo(contextSelection)
        }

        @objc private func revealInFinderFromMenu() {
            parent.model.revealInFinder(contextSelection)
        }

        @objc private func copyPathFromMenu() {
            parent.model.copyPaths(contextSelection)
        }
    }
}

@MainActor
final class BrowserNSTableView: NSTableView {
    var focusHandler: (() -> Void)?
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?
    var keyEventHandler: ((NSEvent) -> Bool)?
    var canCopySelection: (() -> Bool)?
    var copySelection: (() -> Void)?
    var canPasteQueue: (() -> Bool)?
    var pasteQueue: (() -> Void)?
    private var wantsFocusWhenAttached = false

    @objc func copy(_ sender: Any?) {
        guard canCopySelection?() == true else { return }
        copySelection?()
    }

    @objc func paste(_ sender: Any?) {
        guard canPasteQueue?() == true else { return }
        pasteQueue?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            canCopySelection?() == true
        case #selector(paste(_:)):
            canPasteQueue?() == true
        default:
            super.validateUserInterfaceItem(item)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            focusHandler?()
        }
        return becameFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        focusHandler?()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?(event)
    }

    override func keyDown(with event: NSEvent) {
        if keyEventHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocusWhenAttached, window != nil {
            wantsFocusWhenAttached = false
            window?.makeFirstResponder(self)
        }
    }

    func requestFirstResponder() {
        guard let window else {
            wantsFocusWhenAttached = true
            return
        }
        wantsFocusWhenAttached = false
        window.makeFirstResponder(self)
    }
}

@MainActor
final class BrowserTableCellView: NSTableCellView {
    private let column: NativeBrowserTableColumn

    init(column: NativeBrowserTableColumn) {
        self.column = column
        super.init(frame: .zero)
        identifier = column.cellIdentifier
        buildContents()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(with entry: BrowserEntry, column: NativeBrowserTableColumn) {
        switch column {
        case .name:
            imageView?.image = BrowserEntryIcon.image(for: entry)
            imageView?.setAccessibilityLabel(entry.isDirectory ? "Folder" : "File")
            textField?.stringValue = entry.name
            textField?.toolTip = entry.name
            toolTip = entry.name
        case .size:
            textField?.stringValue = entry.formattedSize
            textField?.textColor = entry.isDirectory ? .secondaryLabelColor : .labelColor
        case .modified:
            textField?.stringValue = entry.formattedModifiedDate
        }
    }

    /// A quick springy scale of the icon about its centre, to draw the eye.
    func popIcon() {
        guard let icon = imageView else { return }
        icon.wantsLayer = true
        guard let layer = icon.layer else { return }
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        func scaled(_ scale: CGFloat) -> NSValue {
            var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
            return NSValue(caTransform3D: transform)
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [1, 1.5, 0.9, 1.05, 1].map(scaled)
        animation.keyTimes = [0, 0.3, 0.6, 0.82, 1]
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: 4
        )
        animation.duration = Motion.Duration.slow + 0.1
        layer.add(animation, forKey: "pop")
    }

    private func buildContents() {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        addSubview(label)

        if column == .name {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            imageView = icon
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: BrowserEntryIcon.listSize),
                icon.heightAnchor.constraint(equalToConstant: BrowserEntryIcon.listSize),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }
}

enum NativeBrowserTableColumn: String, CaseIterable {
    case name
    case size
    case modified

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }

    init?(identifier: NSUserInterfaceItemIdentifier) {
        self.init(rawValue: identifier.rawValue)
    }

    var cellIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("BrowserTableCell.\(rawValue)")
    }

    var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .modified: "Modified"
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: 180
        case .size: 75
        case .modified: 125
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .name: 280
        case .size: 95
        case .modified: 155
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .size: 120
        case .name, .modified: .greatestFiniteMagnitude
        }
    }

    func sortDescriptor(ascending: Bool) -> NSSortDescriptor {
        NSSortDescriptor(key: rawValue, ascending: ascending)
    }

    func comparator(order: SortOrder) -> KeyPathComparator<BrowserEntry> {
        switch self {
        case .name: KeyPathComparator(\BrowserEntry.name, order: order)
        case .size: KeyPathComparator(\BrowserEntry.sortableSize, order: order)
        case .modified: KeyPathComparator(\BrowserEntry.sortableModifiedDate, order: order)
        }
    }

    static func resolve(_ comparator: KeyPathComparator<BrowserEntry>) -> Self? {
        if comparator.keyPath == \BrowserEntry.name { return .name }
        if comparator.keyPath == \BrowserEntry.sortableSize { return .size }
        if comparator.keyPath == \BrowserEntry.sortableModifiedDate { return .modified }
        return nil
    }
}

/// How to get the table from one listing to the next without a full reload.
enum BrowserTableRowUpdate: Equatable {
    struct Move: Equatable {
        let from: Int
        let to: Int
    }

    /// Same rows in the same order.
    case unchanged
    /// Too big, unrelated or tangled to animate.
    case reload
    /// Rows left and arrived; the ones that stayed kept their order.
    /// `removed` indexes the old rows, `inserted` the new ones.
    case insertRemove(removed: IndexSet, inserted: IndexSet)
    /// The same rows, re-sorted: apply these moves in order.
    case reorder([Move])
}

enum NativeBrowserTableMapping {
    static func rowUpdate(
        from old: [BrowserEntry.ID],
        to new: [BrowserEntry.ID],
        maxAnimatedRows: Int
    ) -> BrowserTableRowUpdate {
        if old == new { return .unchanged }
        guard !old.isEmpty, !new.isEmpty,
              old.count <= maxAnimatedRows, new.count <= maxAnimatedRows else { return .reload }
        let oldIDs = Set(old)
        let newIDs = Set(new)
        guard oldIDs.count == old.count, newIDs.count == new.count,
              !oldIDs.isDisjoint(with: newIDs) else { return .reload }

        if oldIDs == newIDs {
            var working = old
            var moves: [BrowserTableRowUpdate.Move] = []
            for (target, id) in new.enumerated() where working[target] != id {
                guard let source = working[target...].firstIndex(of: id) else { return .reload }
                working.remove(at: source)
                working.insert(id, at: target)
                moves.append(.init(from: source, to: target))
            }
            return .reorder(moves)
        }

        // Rows that stayed must keep their relative order, or the change is
        // a reshuffle as well and is simpler to reload.
        let stayedInOldOrder = old.filter(newIDs.contains)
        let stayedInNewOrder = new.filter(oldIDs.contains)
        guard stayedInOldOrder == stayedInNewOrder else { return .reload }
        return .insertRemove(
            removed: IndexSet(old.indices.filter { !newIDs.contains(old[$0]) }),
            inserted: IndexSet(new.indices.filter { !oldIDs.contains(new[$0]) })
        )
    }

    /// Rows of `new` whose entry kept its ID but changed (size, date).
    static func rowsWithChangedContent(
        from old: [BrowserEntry],
        to new: [BrowserEntry]
    ) -> IndexSet {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return IndexSet(new.indices.filter { index in
            guard let previous = oldByID[new[index].id] else { return false }
            return previous != new[index]
        })
    }

    static func rowIndexes(
        for selectedEntryIDs: Set<BrowserEntry.ID>,
        in entries: [BrowserEntry]
    ) -> IndexSet {
        IndexSet(entries.indices.filter { selectedEntryIDs.contains(entries[$0].id) })
    }

    static func entryIDs(
        at rowIndexes: IndexSet,
        in entries: [BrowserEntry]
    ) -> Set<BrowserEntry.ID> {
        Set(rowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
    }

    static func sortDescriptors(
        for comparators: [KeyPathComparator<BrowserEntry>]
    ) -> [NSSortDescriptor] {
        comparators.compactMap { comparator in
            NativeBrowserTableColumn.resolve(comparator)?.sortDescriptor(
                ascending: comparator.order == .forward
            )
        }
    }

    static func comparators(
        for sortDescriptors: [NSSortDescriptor]
    ) -> [KeyPathComparator<BrowserEntry>] {
        sortDescriptors.compactMap { descriptor in
            guard let key = descriptor.key,
                  let column = NativeBrowserTableColumn(rawValue: key) else { return nil }
            return column.comparator(order: descriptor.ascending ? .forward : .reverse)
        }
    }
}
