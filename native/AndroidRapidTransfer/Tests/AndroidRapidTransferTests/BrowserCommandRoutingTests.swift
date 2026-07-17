import Foundation
@testable import AndroidRapidTransfer
import AndroidRapidTransferCore
import XCTest

@MainActor
final class BrowserCommandRoutingTests: XCTestCase {
    func testListCommandsAreAvailableWhenNativeTablePaneIsActive() throws {
        let listActions = makeActions(viewMode: .list)
        let routed = BrowserCommandRouting.resolve(
            activePane: .local,
            requestedPane: .device,
            localActions: listActions,
            deviceActions: nil
        )

        XCTAssertEqual(try XCTUnwrap(routed).viewMode, .list)
        XCTAssertTrue(routed?.canCreateFolder == true)
        XCTAssertTrue(routed?.canRefresh == true)
    }


    func testCopyQueueCommandIsUnavailableOnLocalPaneAndRoutesOnDevicePane() throws {
        var didAddToQueue = false
        let localActions = makeActions(viewMode: .list, canAddToCopyQueue: false)
        let deviceActions = makeActions(viewMode: .grid) { didAddToQueue = true }

        let localCommands = try XCTUnwrap(BrowserCommandRouting.resolve(
            activePane: .local,
            requestedPane: .device,
            localActions: localActions,
            deviceActions: deviceActions
        ))
        XCTAssertFalse(localCommands.canAddToCopyQueue)

        let deviceCommands = try XCTUnwrap(BrowserCommandRouting.resolve(
            activePane: .device,
            requestedPane: .local,
            localActions: localActions,
            deviceActions: deviceActions
        ))
        XCTAssertTrue(deviceCommands.canAddToCopyQueue)
        deviceCommands.addToCopyQueue()
        XCTAssertTrue(didAddToQueue)
    }

    func testCopyAndPasteRouteToTheActivePane() throws {
        var invoked: [String] = []
        var localActions = makeActions(viewMode: .list)
        localActions.canCopy = true
        localActions.canPaste = false
        localActions.copy = { invoked.append("local-copy") }
        localActions.paste = { invoked.append("local-paste") }
        var deviceActions = makeActions(viewMode: .grid)
        deviceActions.canCopy = false
        deviceActions.canPaste = true
        deviceActions.copy = { invoked.append("device-copy") }
        deviceActions.paste = { invoked.append("device-paste") }

        let local = try XCTUnwrap(BrowserCommandRouting.resolve(
            activePane: .local,
            requestedPane: .device,
            localActions: localActions,
            deviceActions: deviceActions
        ))
        XCTAssertTrue(local.canCopy)
        XCTAssertFalse(local.canPaste)
        local.copy()

        let device = try XCTUnwrap(BrowserCommandRouting.resolve(
            activePane: .device,
            requestedPane: .local,
            localActions: localActions,
            deviceActions: deviceActions
        ))
        XCTAssertFalse(device.canCopy)
        XCTAssertTrue(device.canPaste)
        device.paste()

        XCTAssertEqual(invoked, ["local-copy", "device-paste"])
    }

    func testClipboardShortcutsMatchClassicBindings() {
        XCTAssertEqual(AppShortcuts.copySelection.displayValue, "⌘C")
        XCTAssertEqual(AppShortcuts.addToCopyQueue.displayValue, "⇧⌘C")
        XCTAssertEqual(AppShortcuts.pasteQueue.displayValue, "⌘V")
        XCTAssertTrue(AppShortcuts.helpListing.contains(AppShortcuts.copySelection))
        XCTAssertTrue(AppShortcuts.helpListing.contains(AppShortcuts.pasteQueue))
    }

    func testDualPaneCommandsTargetActivePaneInListAndGridModes() throws {
        var invokedPanes: [BrowserPaneKind] = []
        let listActions = makeActions(viewMode: .list) { invokedPanes.append(.local) }
        let gridActions = makeActions(viewMode: .grid) { invokedPanes.append(.device) }

        let localCommands = try XCTUnwrap(BrowserCommandRouting.resolve(
            activePane: .local,
            requestedPane: .device,
            localActions: listActions,
            deviceActions: gridActions
        ))
        localCommands.createFolder()
        localCommands.refresh()
        localCommands.setViewMode(.grid)
        localCommands.toggleHiddenFiles()
        XCTAssertEqual(invokedPanes, [.local, .local, .local, .local])

        invokedPanes = []
        let deviceCommands = try XCTUnwrap(BrowserCommandRouting.resolve(
            activePane: .device,
            requestedPane: .local,
            localActions: listActions,
            deviceActions: gridActions
        ))
        deviceCommands.createFolder()
        deviceCommands.refresh()
        deviceCommands.setViewMode(.list)
        deviceCommands.toggleHiddenFiles()
        XCTAssertEqual(invokedPanes, [.device, .device, .device, .device])
    }

    func testSinglePaneCommandsUseRequestedPaneBeforeFocusArrives() throws {
        let coordinator = PaneFocusCoordinator()
        let registrationID = UUID()
        coordinator.requestFocus(.device)
        coordinator.registerBrowserCommands(
            makeActions(viewMode: .grid),
            for: .device,
            registrationID: registrationID
        )

        XCTAssertEqual(try XCTUnwrap(coordinator.browserCommandActions).viewMode, .grid)

        coordinator.unregisterBrowserCommands(
            for: .device,
            registrationID: registrationID
        )
        XCTAssertNil(coordinator.browserCommandActions)
    }

    private func makeActions(
        viewMode: BrowserViewMode,
        canAddToCopyQueue: Bool = true,
        invoke: @escaping () -> Void = {}
    ) -> BrowserCommandActions {
        BrowserCommandActions(
            viewMode: viewMode,
            showsHiddenFiles: false,
            canCreateFolder: true,
            canRefresh: true,
            canGoUp: true,
            canRename: true,
            canDelete: true,
            canAddToCopyQueue: canAddToCopyQueue,
            createFolder: invoke,
            refresh: invoke,
            goUp: {},
            rename: {},
            delete: {},
            addToCopyQueue: invoke,
            setViewMode: { _ in invoke() },
            toggleHiddenFiles: invoke
        )
    }
}
