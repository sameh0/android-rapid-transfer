import AndroidRapidTransferCore
import SwiftUI

struct BrowserPaneView<Model: BrowserPaneModel, Accessory: View>: View {
    @Bindable var model: Model
    let paneKind: BrowserPaneKind
    let settings: AppSettings
    let focusCoordinator: PaneFocusCoordinator
    let isPrimary: Bool
    let copyAction: BrowserCopyAction?
    let queueAction: BrowserCopyAction?
    let dateRangeAction: BrowserCopyAction?
    /// Copy: replaces the transfer queue with this pane's selection.
    let clipboardCopyAction: BrowserCopyAction?
    /// Paste: transfers the queue into this pane's current folder.
    let pasteAction: BrowserCopyAction?
    let navigationDisabled: Bool
    let filePromiseExporter: ((BrowserEntry, URL) async throws -> Void)?
    let dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
    @ViewBuilder let accessory: Accessory
    @FocusState private var isFocused: Bool
    @State private var namePrompt: BrowserNamePrompt?
    @State private var proposedName = ""
    @State private var isNamePromptPresented = false
    @State private var deletionPrompt: FileDeletionConfirmation?
    @State private var isDeleteConfirmationPresented = false
    @State private var infoEntry: BrowserEntry?
    @State private var searchText = ""
    @State private var commandRegistrationID = UUID()
    /// The item just created or renamed, which the listing pops into view.
    @State private var highlight: BrowserEntryHighlight?

    var body: some View {
        VStack(spacing: 0) {
            if !isPrimary {
                PaneHeaderView(title: model.title) {
                    accessory
                }
                Divider()
                BrowserToolbarView(
                    model: model,
                    copyAction: copyAction,
                    queueAction: queueAction,
                    dateRangeAction: dateRangeAction,
                    navigationDisabled: navigationDisabled,
                    createFolder: presentNewFolder
                )
            } else {
                BreadcrumbBarView(
                    model: model,
                    paneKind: paneKind,
                    navigationDisabled: navigationDisabled
                )
                Divider()
            }
            if let error = model.error {
                ErrorBannerView(error: error, dismiss: model.dismissError)
                    .motionTransition(.move(edge: .top).combined(with: .opacity))
            }
            BrowserContentView(
                model: model,
                entries: model.filteredEntries(matching: searchText),
                searchText: searchText,
                navigationDisabled: navigationDisabled,
                filePromiseExporter: filePromiseExporter,
                dragWriter: dragWriter,
                copyAction: copyAction,
                queueAction: queueAction,
                dateRangeAction: dateRangeAction,
                clipboard: clipboardCommands,
                paneKind: paneKind,
                focusCoordinator: focusCoordinator,
                highlight: highlight,
                paneFocus: focusContent,
                createFolder: presentNewFolder,
                rename: presentRename,
                delete: presentDelete,
                showInfo: presentInfo
            )
            Divider()
            if settings.enableStatusBar {
                BrowserStatusBarView(model: model)
                Divider()
            }
            if !isPrimary {
                BreadcrumbBarView(
                    model: model,
                    paneKind: paneKind,
                    navigationDisabled: navigationDisabled
                )
            }
        }
        .motion(Motion.snappy, value: model.error)
        .modifier(
            BrowserPrimaryWindowModifier(
                isEnabled: isPrimary,
                model: model,
                searchText: $searchText,
                navigationDisabled: navigationDisabled,
                copyAction: copyAction,
                queueAction: queueAction,
                dateRangeAction: dateRangeAction,
                createFolder: presentNewFolder,
                accessory: accessory
            )
        )
        .focusable(BrowserPaneFocusTarget.resolve(for: model.viewMode) == .pane)
        .focused($isFocused)
        .focusEffectDisabled()
        .simultaneousGesture(TapGesture().onEnded { focusContent() })
        .onKeyPress(phases: [.down, .repeat], action: handleKeyPress)
        .onChange(of: isFocused) { _, focused in
            if focused {
                focusCoordinator.paneDidFocus(paneKind)
            }
        }
        .onChange(of: focusCoordinator.requestRevision) { _, _ in
            applyPaneFocusRequest()
        }
        .onChange(of: model.viewMode) { _, viewMode in
            handleViewModeChange(viewMode)
        }
        .onChange(of: model.showsHiddenFiles) { _, showsHiddenFiles in
            persist(viewMode: model.viewMode, showsHiddenFiles: showsHiddenFiles)
        }
        .onChange(of: browserCommandState, initial: true) { _, _ in
            focusCoordinator.registerBrowserCommands(
                browserCommandActions,
                for: paneKind,
                registrationID: commandRegistrationID
            )
        }
        .onAppear(perform: requestInitialFocus)
        .onDisappear {
            focusCoordinator.unregisterBrowserCommands(
                for: paneKind,
                registrationID: commandRegistrationID
            )
        }
        .task {
            guard !model.hasLoaded else { return }
            await model.load()
        }
        .alert(namePrompt?.title ?? "Name", isPresented: $isNamePromptPresented) {
            TextField("Name", text: $proposedName)
            Button(namePrompt?.actionTitle ?? "Save", action: submitNamePrompt)
                .keyboardShortcut(.defaultAction)
                .disabled(nameValidationMessage != nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(nameValidationMessage ?? namePrompt?.hint ?? "Enter a name.")
        }
        .alert(
            deletionPrompt?.title ?? "Delete Items?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Delete", role: .destructive, action: confirmDelete)
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deletionPrompt?.message ?? "")
        }
        .popover(item: $infoEntry) { entry in
            FileInfoPopoverView(entry: entry)
        }
    }

    init(
        model: Model,
        paneKind: BrowserPaneKind,
        settings: AppSettings,
        focusCoordinator: PaneFocusCoordinator,
        isPrimary: Bool = false,
        copyAction: BrowserCopyAction? = nil,
        queueAction: BrowserCopyAction? = nil,
        dateRangeAction: BrowserCopyAction? = nil,
        clipboardCopyAction: BrowserCopyAction? = nil,
        pasteAction: BrowserCopyAction? = nil,
        navigationDisabled: Bool = false,
        filePromiseExporter: ((BrowserEntry, URL) async throws -> Void)? = nil,
        dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.model = model
        self.paneKind = paneKind
        self.settings = settings
        self.focusCoordinator = focusCoordinator
        self.isPrimary = isPrimary
        self.copyAction = copyAction
        self.queueAction = queueAction
        self.dateRangeAction = dateRangeAction
        self.clipboardCopyAction = clipboardCopyAction
        self.pasteAction = pasteAction
        self.navigationDisabled = navigationDisabled
        self.filePromiseExporter = filePromiseExporter
        self.dragWriter = dragWriter
        self.accessory = accessory()
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !model.isLoading else { return .handled }

        if AppShortcuts.deleteSelection.matches(keyPress) {
            guard !operationsDisabled else { return .handled }
            presentDelete(model.selectedEntryIDs)
            return .handled
        }

        if keyPress.modifiers.contains(.command), keyPress.key == .upArrow {
            return .ignored
        }

        if AppShortcuts.goUp.matches(keyPress) {
            browserCommandActions.goUp()
            return .handled
        }

        if AppShortcuts.rename.matches(keyPress) {
            browserCommandActions.rename()
            return .handled
        }

        // Reached only when the Edit menu did not claim ⌘C/⌘V, i.e. no text
        // field is editing; the table handles these as responder actions.
        if AppShortcuts.copySelection.matches(keyPress) {
            if browserCommandState.canCopy { clipboardCommands.copy() }
            return .handled
        }

        if AppShortcuts.pasteQueue.matches(keyPress) {
            if browserCommandState.canPaste { clipboardCommands.paste() }
            return .handled
        }

        if AppShortcuts.selectAll.matches(keyPress) {
            model.selectAll()
            return .handled
        }

        if AppShortcuts.clearSelection.matches(keyPress) {
            model.clearSelection()
            return .handled
        }

        if AppShortcuts.openSelection.matches(keyPress) {
            guard !navigationDisabled else { return .handled }
            Task { await model.openSelection() }
            return .handled
        }

        if model.viewMode == .grid,
           AppShortcuts.previousGridItem.matches(keyPress)
            || AppShortcuts.extendToPreviousGridItem.matches(keyPress) {
            model.moveSelection(
                by: -1,
                extending: AppShortcuts.extendToPreviousGridItem.matches(keyPress)
            )
            return .handled
        }

        if model.viewMode == .grid,
           AppShortcuts.nextGridItem.matches(keyPress)
            || AppShortcuts.extendToNextGridItem.matches(keyPress) {
            model.moveSelection(
                by: 1,
                extending: AppShortcuts.extendToNextGridItem.matches(keyPress)
            )
            return .handled
        }

        return .ignored
    }

    private var operationsDisabled: Bool {
        navigationDisabled || model.fileOperationsDisabled || model.isLoading
    }

    private func requestInitialFocus() {
        applyPaneFocusRequest()
    }

    private func focusContent() {
        focusCoordinator.paneDidFocus(paneKind)
        switch BrowserPaneFocusTarget.resolve(for: model.viewMode) {
        case .pane:
            isFocused = true
        case .table:
            isFocused = false
            focusCoordinator.requestFocus(paneKind)
        }
    }

    private func applyPaneFocusRequest() {
        guard focusCoordinator.requestedPane == paneKind else { return }
        switch BrowserPaneFocusTarget.resolve(for: model.viewMode) {
        case .pane:
            isFocused = true
        case .table:
            isFocused = false
        }
    }

    private func handleViewModeChange(_ viewMode: BrowserViewMode) {
        persist(viewMode: viewMode, showsHiddenFiles: model.showsHiddenFiles)
        if focusCoordinator.activePane == paneKind {
            focusContent()
        }
    }

    private var browserCommandActions: BrowserCommandActions {
        let state = browserCommandState
        return BrowserCommandActions(
            viewMode: state.viewMode,
            showsHiddenFiles: state.showsHiddenFiles,
            canCreateFolder: state.canCreateFolder,
            canRefresh: state.canRefresh,
            canGoUp: state.canGoUp,
            canRename: state.canRename,
            canDelete: state.canDelete,
            canAddToCopyQueue: state.canAddToCopyQueue,
            createFolder: presentNewFolder,
            refresh: refresh,
            goUp: goUp,
            rename: { presentRename(model.selectedEntryIDs) },
            delete: { presentDelete(model.selectedEntryIDs) },
            addToCopyQueue: { queueAction?.perform() },
            setViewMode: { model.viewMode = $0 },
            toggleHiddenFiles: toggleHiddenFiles,
            canCopy: state.canCopy,
            canPaste: state.canPaste,
            copy: clipboardCommands.copy,
            paste: clipboardCommands.paste
        )
    }

    private var browserCommandState: BrowserCommandState {
        let clipboard = clipboardCommands
        return BrowserCommandState(
            modelID: ObjectIdentifier(model),
            viewMode: model.viewMode,
            showsHiddenFiles: model.showsHiddenFiles,
            canCreateFolder: !operationsDisabled,
            canRefresh: !model.isLoading && !navigationDisabled,
            canGoUp: model.canGoUp && !model.isLoading && !navigationDisabled,
            canRename: !operationsDisabled && model.selectedEntryIDs.count == 1,
            canDelete: !operationsDisabled && !model.selectedEntryIDs.isEmpty,
            canAddToCopyQueue: !operationsDisabled
                && !model.selectedEntryIDs.isEmpty
                && queueAction?.isEnabled == true,
            canCopy: clipboard.isCopyAvailable && !model.selectedEntryIDs.isEmpty,
            canPaste: clipboard.canPaste
        )
    }

    private var clipboardCommands: BrowserClipboardCommands {
        BrowserClipboardCommands(
            isCopyAvailable: !operationsDisabled && clipboardCopyAction?.isEnabled == true,
            canPaste: !operationsDisabled && pasteAction?.isEnabled == true,
            copy: { clipboardCopyAction?.perform() },
            paste: { pasteAction?.perform() }
        )
    }

    private var nameValidationMessage: String? {
        model.nameValidationMessage(proposedName, renaming: namePrompt?.entry)
    }

    private func presentNewFolder() {
        guard !operationsDisabled else { return }
        namePrompt = BrowserNamePrompt(entry: nil, paneKind: paneKind)
        proposedName = model.suggestedNewFolderName()
        isNamePromptPresented = true
    }

    private func presentRename(_ selection: Set<BrowserEntry.ID>) {
        guard !operationsDisabled,
              selection.count == 1,
              let entry = model.entries.first(where: { selection.contains($0.id) }) else {
            return
        }
        model.selectedEntryIDs = selection
        namePrompt = BrowserNamePrompt(entry: entry, paneKind: paneKind)
        proposedName = entry.name
        isNamePromptPresented = true
    }

    private func presentDelete(_ selection: Set<BrowserEntry.ID>) {
        guard !operationsDisabled, !selection.isEmpty else { return }
        model.selectedEntryIDs = selection
        deletionPrompt = model.deletionConfirmation()
        isDeleteConfirmationPresented = deletionPrompt != nil
    }

    private func presentInfo(_ selection: Set<BrowserEntry.ID>) {
        guard selection.count == 1 else { return }
        infoEntry = model.entries.first(where: { selection.contains($0.id) })
    }

    private func submitNamePrompt() {
        guard nameValidationMessage == nil, let namePrompt else { return }
        let name = proposedName
        Task {
            let succeeded = if namePrompt.entry == nil {
                await model.makeDirectory(named: name)
            } else {
                await model.renameSelectedEntry(to: name)
            }
            if succeeded {
                highlightEntry(named: name)
            }
        }
    }

    /// Selects the item that now carries `name` and pops it into view.
    private func highlightEntry(named name: String) {
        guard let entry = model.entries.first(where: { $0.name == name }) else { return }
        model.selectedEntryIDs = [entry.id]
        highlight = BrowserEntryHighlight(
            entryID: entry.id,
            revision: (highlight?.revision ?? 0) + 1
        )
    }

    private func confirmDelete() {
        Task { _ = await model.deleteSelectedEntries() }
    }

    private func refresh() {
        guard !model.isLoading, !navigationDisabled else { return }
        Task { await model.refresh() }
    }

    private func goUp() {
        guard model.canGoUp, !model.isLoading, !navigationDisabled else { return }
        Task { await model.goUp() }
    }

    private func toggleHiddenFiles() {
        guard !model.isLoading, !navigationDisabled else { return }
        Task { await model.setShowsHiddenFiles(!model.showsHiddenFiles) }
    }

    private func persist(viewMode: BrowserViewMode, showsHiddenFiles: Bool) {
        switch paneKind {
        case .local:
            settings.localViewMode = viewMode
            settings.localShowsHiddenFiles = showsHiddenFiles
        case .device:
            settings.deviceViewMode = viewMode
            settings.deviceShowsHiddenFiles = showsHiddenFiles
        }
    }
}
