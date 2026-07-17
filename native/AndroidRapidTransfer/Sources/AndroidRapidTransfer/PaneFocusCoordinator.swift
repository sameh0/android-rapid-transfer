import Foundation
import Observation
import AndroidRapidTransferCore

@MainActor
@Observable
final class PaneFocusCoordinator {
    private(set) var activePane: BrowserPaneKind?
    private(set) var requestedPane: BrowserPaneKind = .local
    private(set) var requestRevision = 0
    private var localBrowserCommands: RegisteredBrowserCommands?
    private var deviceBrowserCommands: RegisteredBrowserCommands?

    var browserCommandActions: BrowserCommandActions? {
        BrowserCommandRouting.resolve(
            activePane: activePane,
            requestedPane: requestedPane,
            localActions: localBrowserCommands?.actions,
            deviceActions: deviceBrowserCommands?.actions
        )
    }

    func paneDidFocus(_ pane: BrowserPaneKind) {
        activePane = pane
        requestedPane = pane
    }

    func switchPane(showLocalPane: Bool) {
        guard showLocalPane else {
            requestFocus(.device)
            return
        }
        requestFocus(activePane == .local ? .device : .local)
    }

    func ensureValidFocus(showLocalPane: Bool) {
        if !showLocalPane, requestedPane == .local {
            requestFocus(.device)
        }
    }

    func requestFocus(_ pane: BrowserPaneKind) {
        requestedPane = pane
        requestRevision += 1
    }

    func registerBrowserCommands(
        _ actions: BrowserCommandActions,
        for pane: BrowserPaneKind,
        registrationID: UUID
    ) {
        let registration = RegisteredBrowserCommands(id: registrationID, actions: actions)
        switch pane {
        case .local:
            localBrowserCommands = registration
        case .device:
            deviceBrowserCommands = registration
        }
    }

    func unregisterBrowserCommands(for pane: BrowserPaneKind, registrationID: UUID) {
        switch pane {
        case .local:
            guard localBrowserCommands?.id == registrationID else { return }
            localBrowserCommands = nil
        case .device:
            guard deviceBrowserCommands?.id == registrationID else { return }
            deviceBrowserCommands = nil
        }
    }
}

private struct RegisteredBrowserCommands {
    let id: UUID
    let actions: BrowserCommandActions
}
