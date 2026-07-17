import AndroidRapidTransferCore

struct BrowserCommandActions {
    let viewMode: BrowserViewMode
    let showsHiddenFiles: Bool
    let canCreateFolder: Bool
    let canRefresh: Bool
    let canGoUp: Bool
    let canRename: Bool
    let canDelete: Bool
    let canAddToCopyQueue: Bool
    let createFolder: () -> Void
    let refresh: () -> Void
    let goUp: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let addToCopyQueue: () -> Void
    let setViewMode: (BrowserViewMode) -> Void
    let toggleHiddenFiles: () -> Void
    /// Copy: replaces the transfer queue with this pane's selection.
    var canCopy = false
    /// Paste: transfers the queue into this pane's current folder.
    var canPaste = false
    var copy: () -> Void = {}
    var paste: () -> Void = {}
}
