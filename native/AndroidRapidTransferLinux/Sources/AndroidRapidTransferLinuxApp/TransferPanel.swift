import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// The copies panel along the window's bottom edge: an always-visible
/// summary (overall progress, speed, time left, Stop All / Clear) that
/// expands into the list of copies and the copy queue.
@MainActor
final class TransferPanel {
    let root: Revealer
    private let model: TransferViewModel
    private weak var services: (any WindowServices)?
    private let stateIcon = Image(iconName: "object-select-symbolic", pixelSize: 24)
    private let spinner = Spinner().sizeRequest(width: 24, height: 24)
    private let title = Label().css("heading")
    private let subtitle = Label().css("caption", "dim-label", "numeric")
    private let percent = Label().css("title-4", "dim-label", "numeric")
    let stopAllButton = Button("Stop All").css("destructive-action", "small-pill")
    private let clear = Button("Clear").css("small-pill")
    private let countBadge = Label().css("count-badge", "numeric")
    private let expandButton = Button(iconName: "pan-up-symbolic", tooltip: "Show the list of copies").css("flat", "circular")
    private let overallBar = ProgressBar().css("overall-progress")
    private let body: Revealer
    private let tabs = ToggleGroup()
    private let pages = Stack(transition: .crossfade, duration: Motion.Duration.quick)
    private let activityList = ListBox(boxed: false)
    private var rowViews: [UUID: TransferRowView] = [:]
    private var rowOrder: [UUID] = []
    private let queueList = ListBox(boxed: false)
    private let queueStack = Stack(transition: .crossfade, duration: Motion.Duration.quick)
    private let queueSummary = Label().css("caption", "dim-label", "numeric")
    private let queueExecute = Button("Copy to Folder…", iconName: "folder-download-symbolic").css("suggested-action")
    private let queueClear = Button("Clear Queue")
    private var lastOverall: Double = 0
    private var lastSummaryID: UUID?
    private let bag = ObserverBag()

    init(model: TransferViewModel, services: any WindowServices) {
        self.model = model
        self.services = services
        let panel = Box(.vertical, spacing: 0).css("transfer-panel")
        root = Revealer(panel, transition: .slideUp, duration: Motion.Duration.slow)
        body = Revealer(nil, transition: .slideUp, duration: Motion.Duration.standard)

        // Summary row.
        let icons = Stack(transition: .crossfade, duration: Motion.Duration.quick)
        icons.add(stateIcon, name: "icon")
        icons.add(spinner, name: "spinner")
        icons.sizeRequest(width: 28, height: 28)
        title.ellipsis = .end
        title.align(h: .start)
        subtitle.ellipsis = .middle
        subtitle.align(h: .start)
        let titles = Box(.vertical, spacing: 2, [title, subtitle]).align(v: .center).expand(h: true)
        let summaryButton = Button(child: Box(.horizontal, spacing: 12, [icons, titles, percent])).css("flat", "summary-button")
        summaryButton.expand(h: true)
        summaryButton.onClicked { [weak self] in self?.togglePanel() }
        stopAllButton.tooltip = "Stop every copy now. Files already copied stay where they are."
        stopAllButton.align(v: .center)
        stopAllButton.onClicked { Task { await model.stopAll() } }
        clear.tooltip = "Remove finished copies from the list"
        clear.align(v: .center)
        clear.onClicked { [weak self] in self?.animateListChange { model.dismissSettled() } }
        countBadge.align(v: .center)
        expandButton.align(v: .center)
        expandButton.onClicked { [weak self] in self?.togglePanel() }
        let header = Box(.horizontal, spacing: 10, [summaryButton, stopAllButton, clear, countBadge, expandButton]).css("transfer-header")
        panel.append(header)
        panel.append(overallBar)

        // Expanded body: Activity and Queue.
        tabs.add(name: "activity", label: "Activity")
        tabs.add(name: "queue", label: "Queue")
        tabs.activeName = "activity"
        tabs.isHomogeneous = true
        tabs.align(h: .center)
        tabs.onActiveChanged { [weak self] in
            guard let self, let name = self.tabs.activeName else { return }
            self.pages.visibleChildName = name
        }
        activityList.css("transfer-list")
        let activityScroller = ScrolledWindow(activityList)
        activityScroller.setPolicy(h: .never, v: .automatic)
        activityScroller.propagatesNaturalHeight = true
        activityScroller.setProperty("max-content-height", Int32(280))
        pages.isVerticallyHomogeneous = false
        queueStack.isVerticallyHomogeneous = false
        pages.add(activityScroller, name: "activity")
        pages.add(makeQueuePage(), name: "queue")
        let bodyBox = Box(.vertical, spacing: 8, [tabs.margins(top: 4), pages]).css("transfer-body")
        body.child = bodyBox
        panel.append(body)

        installBindings()
    }

    private func makeQueuePage() -> Widget {
        let empty = StatusPage(
            title: "Queue is Empty",
            description: "Copy items in one pane (Ctrl+C, or Ctrl+Shift+C to add), then paste them into the other pane (Ctrl+V).",
            iconName: "edit-paste-symbolic"
        ).css("compact")
        queueList.css("transfer-list")
        let scroller = ScrolledWindow(queueList)
        scroller.setPolicy(h: .never, v: .automatic)
        scroller.propagatesNaturalHeight = true
        scroller.setProperty("max-content-height", Int32(240))
        queueExecute.tooltip = "Copy the queued phone items, keeping their folders, into a folder you choose"
        queueExecute.onClicked { [weak self] in self?.executeQueue() }
        queueClear.onClicked { [weak self] in self?.model.copyQueue.removeAll() }
        let footer = Box(.horizontal, spacing: 8, [queueSummary.expand(h: true).align(h: .start), queueClear, queueExecute]).css("queue-footer")
        let list = Box(.vertical, spacing: 0, [scroller, footer])
        queueStack.add(empty, name: "empty")
        queueStack.add(list, name: "list")
        return queueStack
    }

    private func installBindings() {
        let model = model
        root.bind { $0.isRevealed = model.isPanelVisible }
        body.bind { [weak self] revealer in
            revealer.isRevealed = model.isPanelExpanded
            self?.expandButton.iconName = model.isPanelExpanded ? "pan-down-symbolic" : "pan-up-symbolic"
            self?.expandButton.tooltip = model.isPanelExpanded ? "Hide the list of copies" : "Show the list of copies"
        }
        // Summary line.
        title.bind { [weak self] _ in self?.updateSummary() }
        // Rows.
        activityList.bind { [weak self] _ in self?.updateRows() }
        // Queue.
        queueList.bind { [weak self] _ in self?.updateQueue() }
        tabs.bind { [weak self] _ in
            let count = model.copyQueue.count
            self?.tabs.setToggleLabel(name: "queue", count == 0 ? "Queue" : "Queue (\(count))")
        }
        // A new copy starting opens the Activity tab.
        bag.onChange({ model.rows.count }) { [weak self] count in
            guard let self, count > self.rowOrder.count || self.rowOrder.isEmpty else { return }
            if self.tabs.activeName != "activity", model.rows.contains(where: { !$0.state.isTerminal }) {
                self.tabs.activeName = "activity"
            }
        }
    }

    private func togglePanel() {
        model.togglePanel()
    }

    // MARK: - Summary

    private func updateSummary() {
        let rows = model.rows
        let overall = model.overallProgress
        let summary = model.lastSessionSummary
        let hasFailures = rows.contains { row in
            if case .failed = row.state { return true }
            return !row.fileFailures.isEmpty
        }

        if let overall {
            if overall.totalFiles > 1 {
                title.text = "Copying \(overall.filesCompleted.formatted()) of \(overall.totalFiles.formatted()) files"
            } else if let current = rows.first(where: { !$0.state.isTerminal }) {
                title.text = "Copying \(current.sourceSummary)"
            } else {
                title.text = "Copying…"
            }
            var parts: [String] = []
            if overall.totalBytes > 0 {
                parts.append("\(Format.bytes(overall.sentBytes)) of \(Format.bytes(overall.totalBytes))")
            }
            if overall.speed > 0 { parts.append(TransferRemainingTime.speedText(megabytesPerSecond: overall.speed)) }
            if let remaining = TransferRemainingTime.phrase(overall.eta) {
                parts.append(remaining)
            } else if overall.queuedJobCount > 0, parts.isEmpty {
                parts.append("\(overall.queuedJobCount) waiting")
            }
            subtitle.text = parts.isEmpty ? "Preparing…" : parts.joined(separator: " · ")
            subtitle.isVisible = true
            if let fraction = overall.percent {
                percent.text = "\(Int((fraction * 100).rounded()))%"
                percent.isVisible = true
                animateOverall(to: fraction)
            } else {
                percent.isVisible = false
            }
            overallBar.isVisible = true
            setIcon(spinner: true)
        } else {
            overallBar.isVisible = false
            percent.isVisible = false
            lastOverall = 0
            setIcon(spinner: false)
            if let summary {
                title.text = summary.headline
            } else if hasFailures {
                title.text = "Some copies need attention"
            } else {
                title.text = rows.count == 1 ? "Copy complete" : "Copies complete"
            }
            var parts: [String] = []
            if let summary {
                if summary.bytesCopied > 0 { parts.append(Format.bytes(summary.bytesCopied)) }
                if let destination = summary.destinationPhrase, summary.filesCopied > 0 { parts.append(destination) }
            }
            var text = parts.joined(separator: " ")
            if let summary, summary.itemsFailed > 0 {
                text = (text.isEmpty ? "" : text + " · ") + (model.isPanelExpanded ? "Review the items below" : "Open the list to review")
            }
            subtitle.text = text
            subtitle.isVisible = !text.isEmpty
            let cancelledOnly = summary.map { !$0.isCleanSuccess && $0.jobsCancelled > 0 } ?? false
            stateIcon.iconName = hasFailures ? "dialog-warning-symbolic" : cancelledOnly ? "process-stop-symbolic" : "object-select-symbolic"
            stateIcon.setCSSClass("warning", hasFailures)
            stateIcon.setCSSClass("success", !hasFailures && !cancelledOnly)
            stateIcon.setCSSClass("dim-label", cancelledOnly && !hasFailures)
            if let summary, summary.id != lastSummaryID {
                lastSummaryID = summary.id
                if summary.isCleanSuccess {
                    Animation.spring(on: stateIcon, Motion.celebrate, from: 0.2, to: 1) { [weak stateIcon] value in
                        stateIcon?.pixelSize = Int32(max(8, 24 * value))
                    }.play()
                }
            }
        }
        stopAllButton.isVisible = overall?.isCancellable == true
        clear.isVisible = overall == nil && rows.contains { $0.state.isTerminal }
        countBadge.text = "\(rows.count)"
        countBadge.tooltip = rows.count == 1 ? "1 copy" : "\(rows.count) copies"
    }

    private func setIcon(spinner showSpinner: Bool) {
        spinner.isVisible = showSpinner
        stateIcon.isVisible = !showSpinner
    }

    private func animateOverall(to fraction: Double) {
        let from = lastOverall
        lastOverall = fraction
        guard abs(fraction - from) > 0.001 else { overallBar.fraction = fraction; return }
        Animation.spring(on: overallBar, Motion.snappy, from: from, to: fraction, clamp: true) { [weak overallBar] value in
            overallBar?.fraction = value
        }.play()
    }

    // MARK: - Rows

    private func updateRows() {
        let rows = model.rows
        let ids = rows.map(\.id)
        for row in rows {
            let view = rowViews[row.id] ?? makeRowView(for: row.id)
            view.update(row, canRetry: model.canRetry(row))
        }
        let removed = Set(rowViews.keys).subtracting(ids)
        for id in removed { rowViews.removeValue(forKey: id) }
        if ids != rowOrder {
            activityList.removeAll()
            for id in ids { if let view = rowViews[id] { activityList.append(view.root) } }
            let added = Set(ids).subtracting(rowOrder)
            rowOrder = ids
            for id in added { rowViews[id]?.appear() }
        }
    }

    private func makeRowView(for id: UUID) -> TransferRowView {
        let model = model
        let view = TransferRowView(
            cancel: { Task { await model.cancel(jobID: id) } },
            dismiss: { [weak self] in self?.animateListChange { model.dismiss(jobID: id) } },
            retry: { Task { await model.retry(jobID: id) } },
            services: services
        )
        rowViews[id] = view
        return view
    }

    private func animateListChange(_ body: () -> Void) {
        body()
    }

    // MARK: - Queue

    private func updateQueue() {
        let queue = model.copyQueue
        queueStack.visibleChildName = queue.isEmpty ? "empty" : "list"
        queueList.removeAll()
        for item in queue.items {
            let icon = Image(iconName: "text-x-generic", pixelSize: 24)
            icon.setIconNames(EntryIcons.names(forName: item.displayName, isDirectory: item.isDirectory))
            let name = Label(item.displayName).align(h: .start)
            name.ellipsis = .middle
            let origin = item.source == .device ? "On the phone" : "On this computer"
            let size = item.isDirectory ? "Folder" : (item.size.map(Format.bytes) ?? "Size unknown")
            let detail = Label("\(size) · \(origin)").css("caption", "dim-label").align(h: .start)
            let text = Box(.vertical, spacing: 2, [name, detail]).expand(h: true)
            let remove = Button(iconName: "window-close-symbolic", tooltip: "Remove from the queue").css("flat", "circular")
            let queue = model.copyQueue
            remove.onClicked { queue.remove(id: item.id) }
            queueList.append(Box(.horizontal, spacing: 12, [icon, text, remove]).css("queue-row"))
        }
        var summary = Format.count(queue.count, "item")
        if queue.totalBytes > 0 { summary += " · \(Format.bytes(queue.totalBytes))\(queue.hasUnknownSizes ? "+" : "")" }
        if queue.source == .local { summary += " · paste into the phone pane with Ctrl+V" }
        queueSummary.text = summary
        queueExecute.isSensitive = model.canExecuteCopyQueue
        queueExecute.isVisible = queue.source == .device
    }

    private func executeQueue() {
        let model = model
        Task { [weak self] in
            let dialog = FileDialog(title: "Copy Queued Items To", acceptLabel: "Copy Here")
            dialog.setInitialFolder(model.defaultDownloadDestination)
            guard let folder = try? await dialog.selectFolder(parent: self?.services?.window) else { return }
            if await model.executeCopyQueue(destination: URL(fileURLWithPath: folder)) {
                self?.tabs.activeName = "activity"
                model.isPanelExpanded = true
            }
        }
    }
}

// MARK: - One copy

/// One job in the copies list.
@MainActor
final class TransferRowView {
    let root = Box(.horizontal, spacing: 12).css("transfer-row")
    private let icon = Image(iconName: "text-x-generic", pixelSize: 32)
    private let badge = Image(iconName: "go-down-symbolic", pixelSize: 12)
    private let name = Label().css("heading")
    private let direction = Label().css("caption", "dim-label")
    private let progress = ProgressBar().css("row-progress")
    private let detail = Label().css("caption", "dim-label", "numeric")
    private let failureTitle = Label().css("error", "heading")
    private let guidance = Label().css("caption", "dim-label")
    private let detailsToggle = Button("Details").css("flat", "details-toggle")
    private let detailsText = Label().css("caption", "monospace", "dim-label")
    private let detailsReveal: Revealer
    private let stopButton = Button(iconName: "media-playback-stop-symbolic", tooltip: "Stop now. Files already copied stay.").css("flat", "circular")
    private let stopping = Spinner().sizeRequest(width: 16, height: 16)
    private let retryButton = Button(iconName: "view-refresh-symbolic", tooltip: "Try this copy again").css("flat", "circular")
    private let revealButton = Button(iconName: "folder-open-symbolic", tooltip: "Show in Files").css("flat", "circular")
    private let dismissButton = Button(iconName: "window-close-symbolic", tooltip: "Remove from the list").css("flat", "circular")
    private var lastFraction: Double = 0
    private var lastStateKey = ""
    private var row: TransferPanelRow?
    private weak var services: (any WindowServices)?

    init(cancel: @escaping @MainActor () -> Void, dismiss: @escaping @MainActor () -> Void,
         retry: @escaping @MainActor () -> Void, services: (any WindowServices)?) {
        self.services = services
        detailsReveal = Revealer(nil, transition: .slideDown, duration: Motion.Duration.standard)
        name.ellipsis = .middle
        name.align(h: .start)
        direction.align(h: .start)
        let nameRow = Box(.horizontal, spacing: 6, [name, direction])
        detail.ellipsis = .middle
        detail.align(h: .start)
        failureTitle.align(h: .start)
        guidance.wraps = true
        guidance.align(h: .start)
        guidance.xalign = 0
        detailsText.wraps = true
        detailsText.isSelectable = true
        detailsText.align(h: .start)
        let copyDetails = Button(iconName: "edit-copy-symbolic", tooltip: "Copy the technical details, for a bug report").css("flat").align(v: .start)
        copyDetails.onClicked { [weak detailsText] in Clipboard.setText(detailsText?.text ?? "") }
        detailsReveal.child = Box(.horizontal, spacing: 6, [detailsText.expand(h: true), copyDetails]).css("card", "details-card")
        detailsToggle.align(h: .start)
        detailsToggle.onClicked { [weak self] in
            guard let self else { return }
            self.detailsReveal.isRevealed.toggle()
            self.detailsToggle.label = self.detailsReveal.isRevealed ? "Hide Details" : "Details"
        }
        let text = Box(.vertical, spacing: 4, [nameRow, progress, detail, failureTitle, guidance, detailsToggle, detailsReveal]).expand(h: true)
        let iconStack = Overlay(icon)
        badge.align(h: .end, v: .end)
        badge.css("direction-badge")
        iconStack.addOverlay(badge)
        iconStack.align(v: .start)
        stopButton.onClicked(cancel)
        dismissButton.onClicked(dismiss)
        retryButton.onClicked(retry)
        revealButton.onClicked { [weak self] in self?.reveal() }
        let buttons = Box(.horizontal, spacing: 2, [stopping, stopButton, retryButton, revealButton, dismissButton]).align(v: .center)
        root.append(iconStack)
        root.append(text)
        root.append(buttons)
    }

    /// A quick fade-in for a row that just joined the list.
    func appear() {
        Animation.spring(on: root, Motion.bouncy, property: "opacity", from: 0, to: 1).play()
    }

    func update(_ row: TransferPanelRow, canRetry: Bool) {
        self.row = row
        let isDownload = row.request.direction == .download
        name.text = row.sourceSummary
        direction.text = isDownload ? "to computer" : "to phone"
        let from = row.sourceDirectory ?? "/"
        root.tooltip = isDownload
            ? "From \(from) on the phone to \(row.request.destination) on this computer"
            : "From \(from) on this computer to \(row.request.destination) on the phone"
        let isFolder = row.request.sources.count == 1 && row.request.directorySources.contains(row.request.sources[0])
        if row.request.sources.count > 1 {
            icon.setIconNames(["folder-documents", "folder"])
        } else {
            icon.setIconNames(EntryIcons.names(forName: row.sourceSummary, isDirectory: isFolder))
        }
        badge.iconName = isDownload ? "go-down-symbolic" : "go-up-symbolic"

        var showProgress = false
        var detailText: String?
        var failure: TransferFailureDescription?
        var isActive = false
        var isTerminal = false
        switch row.state {
        case .queued:
            detailText = "Waiting…"
        case .preprocessing:
            showProgress = true
            isActive = true
            detailText = row.cancelRequested ? "Stopping…" : "Preparing…"
            setFraction(0)
        case let .transferring(snapshot):
            showProgress = true
            isActive = true
            setFraction(snapshot.fraction)
            var parts: [String] = []
            parts.append(row.cancelRequested ? "Stopping…" : snapshot.currentFileName)
            if snapshot.totalFiles > 1 { parts.append("\(snapshot.filesSent) of \(snapshot.totalFiles)") }
            if snapshot.totalBytes > 0 { parts.append("\(Format.bytes(snapshot.sentBytes)) of \(Format.bytes(snapshot.totalBytes))") }
            if snapshot.speed > 0 { parts.append(TransferRemainingTime.speedText(megabytesPerSecond: snapshot.speed)) }
            if let remaining = TransferRemainingTime.phrase(snapshot.eta) { parts.append(remaining) }
            detailText = parts.joined(separator: " · ")
        case .completed:
            isTerminal = true
            var text = row.fileFailures.isEmpty ? "Copied" : "Copied with problems"
            switch (row.totalBytes, row.duration) {
            case let (bytes?, duration?): text += " · \(Format.bytes(bytes)) in \(Format.duration(duration))"
            case let (bytes?, nil): text += " · \(Format.bytes(bytes))"
            case let (nil, duration?): text += " · in \(Format.duration(duration))"
            case (nil, nil): break
            }
            if !row.fileFailures.isEmpty {
                text += " · " + (row.fileFailures.count == 1 ? "1 file failed" : "\(row.fileFailures.count) files failed")
            }
            detailText = text
        case let .failed(description):
            isTerminal = true
            failure = description
            if let sent = row.sentBytes, sent > 0 {
                detailText = row.totalBytes.map { "\(Format.bytes(sent)) of \(Format.bytes($0)) copied before it stopped" }
                    ?? "\(Format.bytes(sent)) copied before it stopped"
            }
        case .cancelled:
            isTerminal = true
            if let progress = row.lastProgress, progress.filesSent > 0 {
                detailText = "Stopped · \(progress.filesSent) of \(progress.totalFiles) files copied"
            } else {
                detailText = "Stopped"
            }
        }

        progress.isVisible = showProgress
        progress.setCSSClass("stopping", row.cancelRequested)
        progress.setCSSClass("upload", !isDownload)
        detail.text = detailText ?? ""
        detail.isVisible = detailText != nil
        detail.setCSSClass("warning", row.cancelRequested)
        failureTitle.isVisible = failure != nil
        guidance.isVisible = failure != nil
        failureTitle.text = failure?.title ?? ""
        guidance.text = failure?.guidance ?? ""
        let technical = detailLines(row: row, technical: failure?.technicalDetail)
        detailsToggle.isVisible = !technical.isEmpty
        detailsText.text = technical
        if technical.isEmpty { detailsReveal.isRevealed = false }
        root.setCSSClass("failed", failure != nil)

        stopButton.isVisible = (isActive && !row.cancelRequested) || row.state == .queued
        stopButton.tooltip = row.state == .queued ? "Remove from the queue" : "Stop now. Files already copied stay."
        stopButton.iconName = row.state == .queued ? "window-close-symbolic" : "media-playback-stop-symbolic"
        stopping.isVisible = isActive && row.cancelRequested
        retryButton.isVisible = isTerminal && canRetry
        retryButton.tooltip = row.fileFailures.isEmpty ? "Try this copy again" : "Copy the files that failed again"
        revealButton.isVisible = isTerminal && row.state == .completed && !row.localResultPaths.isEmpty
        dismissButton.isVisible = isTerminal

        let stateKey = "\(row.state.isTerminal)-\(failure != nil)"
        if stateKey != lastStateKey {
            if failure != nil, !lastStateKey.isEmpty { shake() }
            lastStateKey = stateKey
        }
    }

    private func setFraction(_ fraction: Double) {
        let from = lastFraction
        lastFraction = fraction
        if fraction < from || abs(fraction - from) < 0.001 {
            progress.fraction = fraction
            return
        }
        Animation.spring(on: progress, Motion.snappy, from: from, to: fraction, clamp: true) { [weak progress] value in
            progress?.fraction = value
        }.play()
    }

    private func shake() {
        Animation.spring(on: root, Motion.celebrate, from: 1, to: 0) { [weak root] value in
            root?.margins(start: Int32(abs(value) * 8))
        }.play()
    }

    private func detailLines(row: TransferPanelRow, technical: String?) -> String {
        var lines: [String] = []
        if let technical { lines.append(technical) }
        for (failure, description) in zip(row.fileFailures, row.fileFailureDescriptions) {
            let name = URL(fileURLWithPath: failure.source).lastPathComponent
            lines.append("\(name) — \(description.title): \(failure.message)")
        }
        return lines.joined(separator: "\n")
    }

    private func reveal() {
        guard let row else { return }
        let existing = row.localResultPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if let first = existing.first {
            Launcher.showInFileManager(path: first, parent: services?.window)
        } else {
            Launcher.open(path: row.request.destination, parent: services?.window)
        }
    }
}
