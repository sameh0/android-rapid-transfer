/// Copy and Paste for one pane, resolved once so the Edit menu, the browser's
/// key handling, the table's responder actions, and the context menu all agree
/// on availability.
///
/// Copy replaces the transfer queue with the pane's selection; Paste transfers
/// the queue into the pane's current folder when it was copied from the other
/// pane. Copy to Queue (append) keeps using the pane's `queueAction`.
struct BrowserClipboardCommands {
    /// Copy is possible in this pane once something is selected. Selection is
    /// checked by each surface, because the context menu acts on the
    /// right-clicked rows rather than the pane's stored selection.
    var isCopyAvailable = false
    var canPaste = false
    var copy: () -> Void = {}
    var paste: () -> Void = {}

    static var unavailable: BrowserClipboardCommands { BrowserClipboardCommands() }
}
