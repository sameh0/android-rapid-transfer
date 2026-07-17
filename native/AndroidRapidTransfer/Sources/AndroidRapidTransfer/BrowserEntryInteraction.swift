import AppKit
import AndroidRapidTransferCore

enum BrowserEntryInteraction {
    static func selectionOptions(
        for modifiers: NSEvent.ModifierFlags
    ) -> (extendsSelection: Bool, togglesSelection: Bool) {
        (
            extendsSelection: modifiers.contains(.shift),
            togglesSelection: modifiers.contains(.command)
        )
    }

    /// Whether a mouseDown completes a double-click. AppKit keeps incrementing
    /// `NSEvent.clickCount` for successive clicks at the same location within
    /// the double-click interval, so drilling through nested folders (each
    /// folder appearing at the same coordinates) yields pairs like (3,4) —
    /// a strict `clickCount == 2` check misses every pair after the first.
    static func isOpenClick(clickCount: Int) -> Bool {
        clickCount >= 2 && clickCount.isMultiple(of: 2)
    }
}

@MainActor
extension BrowserPaneModel {
    func selectBrowserEntry(
        _ entry: BrowserEntry,
        modifiers: NSEvent.ModifierFlags
    ) {
        let options = BrowserEntryInteraction.selectionOptions(for: modifiers)
        selectEntry(
            id: entry.id,
            extending: options.extendsSelection,
            toggling: options.togglesSelection
        )
    }

    /// Folders open in place; a local file opens in its default app; a device
    /// file does nothing (see ``BrowserPaneModel/openEntry(_:)``).
    func openBrowserEntry(_ entry: BrowserEntry, navigationDisabled: Bool) {
        guard !navigationDisabled else { return }
        Task { await openEntry(entry) }
    }
}
