import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// Asks what to do when a copy would land on an existing item: the item
/// already there and the one being copied side by side, and Skip, Keep Both
/// or Replace, optionally for every conflict in this copy. Pointing at a
/// choice previews it (Replace dims the existing item, Skip the incoming).
@MainActor
final class ConflictDialog {
    let prompt: FileConflictPrompt
    let dialog = Dialog(title: "File Already Exists", width: 520)
    private let resolve: (FileConflictResolution, Bool) -> Void
    private let applyToAll = CheckButton("Do the same for every conflict in this copy")
    private var existingCard: Widget!
    private var incomingCard: Widget!
    private let outcome = Label("Point at a choice to see what it does.").css("caption", "dim-label")
    private var isResolved = false

    init(prompt: FileConflictPrompt, resolve: @escaping (FileConflictResolution, Bool) -> Void) {
        self.prompt = prompt
        self.resolve = resolve
        build()
    }

    private func build() {
        let toolbar = ToolbarView()
        let header = HeaderBar()
        header.setProperty("show-end-title-buttons", false)
        header.setProperty("show-start-title-buttons", false)
        toolbar.addTopBar(header)

        let icon = Image(iconName: "edit-copy-symbolic", pixelSize: 32).css("warning").align(v: .start)
        let heading = Label("“\(prompt.fileName)” already exists").css("title-3")
        heading.wraps = true
        heading.align(h: .start)
        heading.xalign = 0
        let folderName = URL(fileURLWithPath: prompt.destination).lastPathComponent
        let place = folderName.isEmpty || folderName == "/" ? "the top folder" : "“\(folderName)”"
        let subheading = Label("in \(place)").css("dim-label").align(h: .start)
        subheading.ellipsis = .middle
        subheading.tooltip = prompt.destination
        let titles = Box(.vertical, spacing: 4, [heading, subheading]).expand(h: true)
        let top = Box(.horizontal, spacing: 12, [icon, titles])

        existingCard = card(caption: "Already there", item: prompt.existing, against: prompt.incoming)
        incomingCard = card(caption: "Copying", item: prompt.incoming, against: prompt.existing)
        let arrow = Image(iconName: "go-previous-symbolic").css("dim-label").align(v: .center)
        let cards = Box(.horizontal, spacing: 10, [existingCard, arrow, incomingCard])
        cards.isHomogeneous = false
        outcome.align(h: .start)
        outcome.wraps = true

        let skip = Button("Skip")
        let keepBoth = Button("Keep Both").css("suggested-action")
        let replace = Button("Replace").css("destructive-action")
        skip.tooltip = "Don’t copy this item"
        keepBoth.tooltip = "Copy it with a number added to its name"
        replace.tooltip = "Overwrite the existing item"
        let buttons = Box(.horizontal, spacing: 8, [skip, Box().expand(h: true), keepBoth, replace])
        for (button, resolution) in [(skip, FileConflictResolution.skip), (keepBoth, .keepBoth), (replace, .replace)] {
            button.onClicked { [weak self] in self?.choose(resolution) }
            let hover = HoverController()
            hover.onEnter { [weak self] in self?.preview(resolution) }
            hover.onLeave { [weak self] in self?.preview(nil) }
            button.add(hover)
            let focus = FocusController()
            focus.onEnter { [weak self] in self?.preview(resolution) }
            button.add(focus)
        }

        let content = Box(.vertical, spacing: 18, [top, cards, outcome, applyToAll, buttons]).margins(top: 6, bottom: 24, start: 24, end: 24)
        toolbar.content = content
        dialog.child = toolbar
        dialog.setDefaultWidget(keepBoth)
        dialog.setFocus(keepBoth)
        // Escape (or the close button) skips, as the Mac dialog's Cancel does.
        dialog.canClose = false
        dialog.onCloseAttempt { [weak self] in self?.choose(.skip) }
    }

    private func card(caption: String, item: FileConflictItem?, against other: FileConflictItem?) -> Widget {
        let captionLabel = Label(caption.uppercased()).css("caption-heading", "dim-label")
        let icon = Image(iconName: "text-x-generic", pixelSize: 48)
        icon.setIconNames(EntryIcons.names(forName: prompt.fileName, isDirectory: item?.isDirectory ?? false))
        var children: [Widget] = [captionLabel, icon]
        if let location = item?.location {
            let where_ = Box(.horizontal, spacing: 4, [
                Image(iconName: location == .mac ? "computer-symbolic" : "phone-symbolic"),
                Label(location == .mac ? "On this computer" : "On the phone")
            ]).css("caption", "dim-label").align(h: .center)
            children.append(where_)
        }
        let size: String
        if let item {
            size = item.isDirectory ? "Folder" : (item.size.map(Format.bytes) ?? "Size unknown")
        } else {
            size = "Size unknown"
        }
        children.append(Label(size).css("caption", "numeric"))
        children.append(Label(item?.modified.map { Format.date($0) } ?? "Date unknown").css("caption", "dim-label"))
        let badgeText: String? = {
            guard let item, let other else { return nil }
            switch item.comparison(to: other) {
            case .newer: return "Newer"
            case .larger: return "Larger"
            case .sameSize: return "Same size"
            case .older, .smaller, .unknown: return nil
            }
        }()
        let badge = Label(badgeText ?? " ").css("conflict-badge", "caption-heading")
        badge.opacity = badgeText == nil ? 0 : 1
        children.append(badge.align(h: .center))
        return Box(.vertical, spacing: 6, children).css("card", "conflict-card").expand(h: true).sizeRequest(width: 200)
    }

    private func preview(_ resolution: FileConflictResolution?) {
        existingCard.setCSSClass("dimmed", resolution == .replace)
        incomingCard.setCSSClass("dimmed", resolution == .skip)
        outcome.text = switch resolution {
        case .replace: "Replace overwrites the item that’s already there."
        case .skip: "Skip leaves the existing item alone and doesn’t copy this one."
        case .keepBoth: "Keep Both copies this one with a number added to its name."
        case nil: "Point at a choice to see what it does."
        }
    }

    func choose(_ resolution: FileConflictResolution) {
        guard !isResolved else { return }
        isResolved = true
        resolve(resolution, applyToAll.isActive)
        dialog.forceClose()
    }

    /// Closes without answering (the prompt was withdrawn by Core).
    func withdraw() {
        guard !isResolved else { return }
        isResolved = true
        dialog.forceClose()
    }

    /// For the self-test: tick "apply to all".
    func setApplyToAll(_ value: Bool) { applyToAll.isActive = value }
}
