import AndroidRapidTransferCore

struct BrowserNamePrompt {
    let entry: BrowserEntry?
    var paneKind: BrowserPaneKind = .local

    var title: String {
        entry == nil ? "New Folder" : "Rename Item"
    }

    var actionTitle: String {
        entry == nil ? "Create" : "Rename"
    }

    /// Shown while the name is valid. Renaming on the phone carries a warning
    /// because MTP rename support varies by device.
    var hint: String {
        guard entry != nil, paneKind == .device else { return "Enter a name." }
        return "Enter a name. Not all phones will support the rename feature."
    }
}
