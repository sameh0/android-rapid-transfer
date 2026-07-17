import AndroidRapidTransferCore

struct BrowserCommandState: Equatable {
    let modelID: ObjectIdentifier
    let viewMode: BrowserViewMode
    let showsHiddenFiles: Bool
    let canCreateFolder: Bool
    let canRefresh: Bool
    let canGoUp: Bool
    let canRename: Bool
    let canDelete: Bool
    let canAddToCopyQueue: Bool
    var canCopy = false
    var canPaste = false
}
