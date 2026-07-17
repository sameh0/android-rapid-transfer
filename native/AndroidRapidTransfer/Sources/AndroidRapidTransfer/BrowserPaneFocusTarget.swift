import AndroidRapidTransferCore

enum BrowserPaneFocusTarget: Equatable {
    case pane
    case table

    static func resolve(for viewMode: BrowserViewMode) -> Self {
        switch viewMode {
        case .list:
            .table
        case .grid:
            .pane
        }
    }
}
