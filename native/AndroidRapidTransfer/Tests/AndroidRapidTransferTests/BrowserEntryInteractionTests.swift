import AppKit
import AndroidRapidTransferCore
import XCTest
@testable import AndroidRapidTransfer

final class BrowserEntryInteractionTests: XCTestCase {
    func testSelectionOptionsMapShiftAndCommandIndependently() {
        assertSelectionOptions([], extendsSelection: false, togglesSelection: false)
        assertSelectionOptions(.shift, extendsSelection: true, togglesSelection: false)
        assertSelectionOptions(.command, extendsSelection: false, togglesSelection: true)
        assertSelectionOptions(
            [.shift, .command],
            extendsSelection: true,
            togglesSelection: true
        )
        assertSelectionOptions(.control, extendsSelection: false, togglesSelection: false)
    }

    @MainActor
    func testDoubleClickOpensLocalFilesUnlessNavigationIsDisabled() async {
        let opener = RecordingFileOpener()
        let model = LocalBrowserViewModel(
            rootURL: FileManager.default.temporaryDirectory,
            fileOpener: opener
        )
        let file = makeEntry(isDirectory: false)

        model.openBrowserEntry(file, navigationDisabled: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(opener.openedURLs.isEmpty)

        model.openBrowserEntry(file, navigationDisabled: false)
        for _ in 0..<5 where opener.openedURLs.isEmpty { await Task.yield() }
        XCTAssertEqual(opener.openedURLs, [URL(fileURLWithPath: "/File.txt")])
    }

    @MainActor
    func testWorkspaceActionsRevealAndOpenThroughTheInjectedWorkspace() {
        let workspace = RecordingWorkspace()
        let urls = [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b")]

        BrowserSystemActions.revealInFinder(urls, workspace: workspace)
        BrowserSystemActions.revealInFinder([], workspace: workspace)
        XCTAssertEqual(workspace.revealed, [urls])

        WorkspaceFileOpener(workspace: workspace).open(urls[0])
        XCTAssertEqual(workspace.opened, [urls[0]])
    }

    @MainActor
    func testCopyPathsWritesOnePathPerLineAndIgnoresEmptySelections() {
        let pasteboard = RecordingPasteboard()

        BrowserSystemActions.copyPaths([], to: pasteboard)
        XCTAssertEqual(pasteboard.clearCount, 0)

        BrowserSystemActions.copyPaths(["/DCIM/Camera/a.jpg", "/DCIM/Camera/b.jpg"], to: pasteboard)
        XCTAssertEqual(pasteboard.clearCount, 1)
        XCTAssertEqual(pasteboard.strings, ["/DCIM/Camera/a.jpg\n/DCIM/Camera/b.jpg"])
        XCTAssertEqual(pasteboard.types, [.string])
    }

    func testOpenClickMatchesEveryCompletedDoubleClickInAnEscalatingSeries() {
        // macOS keeps incrementing NSEvent.clickCount for successive clicks at
        // the same location within the double-click interval, so drilling into
        // nested folders produces pairs like (3,4) and (5,6).
        XCTAssertFalse(BrowserEntryInteraction.isOpenClick(clickCount: 0))
        XCTAssertFalse(BrowserEntryInteraction.isOpenClick(clickCount: 1))
        XCTAssertTrue(BrowserEntryInteraction.isOpenClick(clickCount: 2))
        XCTAssertFalse(BrowserEntryInteraction.isOpenClick(clickCount: 3))
        XCTAssertTrue(BrowserEntryInteraction.isOpenClick(clickCount: 4))
        XCTAssertFalse(BrowserEntryInteraction.isOpenClick(clickCount: 5))
        XCTAssertTrue(BrowserEntryInteraction.isOpenClick(clickCount: 6))
    }

    func testMouseDownRoutesAlwaysFocusPaneAndForwardOnlyNativeTrackingBranches() {
        var paneFocusCount = 0
        let paneFocus = { paneFocusCount += 1 }

        XCTAssertEqual(
            BrowserCellMouseDownRoute.resolve(
                modifierFlags: .control,
                usesNativeMouseTrackingWhenDragUnavailable: false,
                hasExporter: true,
                hasDragWriter: false,
                paneFocus: paneFocus
            ),
            .forwardToNativeView
        )
        XCTAssertEqual(
            BrowserCellMouseDownRoute.resolve(
                modifierFlags: [],
                usesNativeMouseTrackingWhenDragUnavailable: true,
                hasExporter: false,
                hasDragWriter: false,
                paneFocus: paneFocus
            ),
            .forwardToNativeView
        )
        XCTAssertEqual(
            BrowserCellMouseDownRoute.resolve(
                modifierFlags: [],
                usesNativeMouseTrackingWhenDragUnavailable: true,
                hasExporter: true,
                hasDragWriter: false,
                paneFocus: paneFocus
            ),
            .consume
        )
        XCTAssertEqual(paneFocusCount, 3)
    }

    func testPaneFocusTargetRoutesListToTableAndGridToPane() {
        XCTAssertEqual(BrowserPaneFocusTarget.resolve(for: .list), .table)
        XCTAssertEqual(BrowserPaneFocusTarget.resolve(for: .grid), .pane)
    }

    @MainActor
    func testFilePromiseProviderRetainsDelegateUntilWriteCompletion() async throws {
        let entry = makeEntry(isDirectory: false)
        var delegate: DeviceFilePromiseDelegate? = DeviceFilePromiseDelegate(
            entry: entry,
            exporter: { _, _ in }
        )
        let weakDelegate = WeakReference(delegate)
        let provider = try XCTUnwrap(delegate?.makeProvider())

        delegate = nil
        XCTAssertNotNil(weakDelegate.value)
        XCTAssertTrue((provider.userInfo as AnyObject?) === weakDelegate.value)

        let completion = expectation(description: "file promise completed")
        weakDelegate.value?.filePromiseProvider(
            provider,
            writePromiseTo: FileManager.default.temporaryDirectory
        ) { error in
            XCTAssertNil(error)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 1)
        await Task.yield()

        XCTAssertNil(provider.userInfo)
        XCTAssertNil(weakDelegate.value)
    }

    private func makeEntry(isDirectory: Bool) -> BrowserEntry {
        BrowserEntry(
            id: isDirectory ? "directory" : "file",
            name: isDirectory ? "Folder" : "File.txt",
            size: nil,
            modified: nil,
            isDirectory: isDirectory,
            location: isDirectory ? "/Folder" : "/File.txt"
        )
    }

    private func assertSelectionOptions(
        _ modifiers: NSEvent.ModifierFlags,
        extendsSelection: Bool,
        togglesSelection: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let options = BrowserEntryInteraction.selectionOptions(for: modifiers)
        XCTAssertEqual(options.extendsSelection, extendsSelection, file: file, line: line)
        XCTAssertEqual(options.togglesSelection, togglesSelection, file: file, line: line)
    }
}

@MainActor
private final class RecordingFileOpener: LocalFileOpening {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

@MainActor
private final class RecordingWorkspace: WorkspaceActions {
    private(set) var opened: [URL] = []
    private(set) var revealed: [[URL]] = []

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return true
    }

    func activateFileViewerSelecting(_ fileURLs: [URL]) {
        revealed.append(fileURLs)
    }
}

@MainActor
private final class RecordingPasteboard: StringPasteboard {
    private(set) var clearCount = 0
    private(set) var strings: [String] = []
    private(set) var types: [NSPasteboard.PasteboardType] = []

    func clearContents() -> Int {
        clearCount += 1
        return clearCount
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        strings.append(string)
        types.append(dataType)
        return true
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
