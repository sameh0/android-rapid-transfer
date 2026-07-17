import AndroidRapidTransferCore

enum BrowserCommandRouting {
    static func resolve(
        activePane: BrowserPaneKind?,
        requestedPane: BrowserPaneKind,
        localActions: BrowserCommandActions?,
        deviceActions: BrowserCommandActions?
    ) -> BrowserCommandActions? {
        if let actions = actions(
            for: activePane,
            localActions: localActions,
            deviceActions: deviceActions
        ) {
            return actions
        }
        return actions(
            for: requestedPane,
            localActions: localActions,
            deviceActions: deviceActions
        )
    }

    private static func actions(
        for pane: BrowserPaneKind?,
        localActions: BrowserCommandActions?,
        deviceActions: BrowserCommandActions?
    ) -> BrowserCommandActions? {
        switch pane {
        case .local:
            localActions
        case .device:
            deviceActions
        case nil:
            nil
        }
    }
}
