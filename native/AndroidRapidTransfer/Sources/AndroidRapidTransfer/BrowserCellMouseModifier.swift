import AppKit
import AndroidRapidTransferCore
import SwiftUI
import UniformTypeIdentifiers

private func makeDragImage(for entry: BrowserEntry) -> NSImage {
    let symbolName = entry.isDirectory ? "folder.fill" : "doc.fill"
    return NSImage(systemSymbolName: symbolName, accessibilityDescription: entry.name)
        ?? NSImage(size: NSSize(width: 32, height: 32))
}

/// Always-on AppKit mouse handler for browser cells. SwiftUI's double-tap
/// gesture loses clicks when combined with table selection and drag gestures
/// on macOS, so selection, open, dragging and hover share this single event
/// path. (This view sits on top of the cell, so SwiftUI's `onHover` on the
/// cell underneath would never fire.)
struct BrowserCellMouseModifier: ViewModifier {
    let entry: BrowserEntry
    let isSelected: Bool
    let selectionCount: Int
    /// Resolves the full selection only after a file-promise drag starts.
    let selectedEntriesProvider: () -> [BrowserEntry]
    let paneFocus: () -> Void
    let select: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    let exporter: ((BrowserEntry, URL) async throws -> Void)?
    let dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
    var hoverChanged: ((Bool) -> Void)?
    var usesNativeMouseTrackingWhenDragUnavailable = false

    func body(content: Content) -> some View {
        content.overlay {
            DeviceFilePromiseDragView(
                entry: entry,
                isSelected: isSelected,
                selectionCount: selectionCount,
                selectedEntriesProvider: selectedEntriesProvider,
                paneFocus: paneFocus,
                select: select,
                open: open,
                exporter: exporter,
                dragWriter: dragWriter,
                hoverChanged: hoverChanged,
                usesNativeMouseTrackingWhenDragUnavailable:
                    usesNativeMouseTrackingWhenDragUnavailable
            )
        }
    }
}

private struct DeviceFilePromiseDragView: NSViewRepresentable {
    let entry: BrowserEntry
    let isSelected: Bool
    let selectionCount: Int
    let selectedEntriesProvider: () -> [BrowserEntry]
    let paneFocus: () -> Void
    let select: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    let exporter: ((BrowserEntry, URL) async throws -> Void)?
    let dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
    let hoverChanged: ((Bool) -> Void)?
    let usesNativeMouseTrackingWhenDragUnavailable: Bool

    func makeNSView(context: Context) -> DragSourceView {
        DragSourceView()
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.entry = entry
        view.isSelected = isSelected
        view.selectionCount = selectionCount
        view.selectedEntriesProvider = selectedEntriesProvider
        view.paneFocus = paneFocus
        view.select = select
        view.open = open
        view.exporter = exporter
        view.dragWriter = dragWriter
        view.hoverChanged = hoverChanged
        view.usesNativeMouseTrackingWhenDragUnavailable =
            usesNativeMouseTrackingWhenDragUnavailable
    }

    @MainActor
    final class DragSourceView: NSView, NSDraggingSource {
        var entry: BrowserEntry?
        var isSelected = false
        var selectionCount = 0
        var selectedEntriesProvider: () -> [BrowserEntry] = { [] }
        var paneFocus: (() -> Void)?
        var select: ((NSEvent.ModifierFlags) -> Void)?
        var open: (() -> Void)?
        var exporter: ((BrowserEntry, URL) async throws -> Void)?
        var dragWriter: ((BrowserEntry) -> NSPasteboardWriting?)?
        var hoverChanged: ((Bool) -> Void)?
        var usesNativeMouseTrackingWhenDragUnavailable = false

        private var mouseDownPoint: NSPoint?
        private var hoverTrackingArea: NSTrackingArea?
        private var isHovered = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            setHovered(true)
        }

        override func mouseExited(with event: NSEvent) {
            setHovered(false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setHovered(false) }
        }

        private func setHovered(_ hovered: Bool) {
            guard hovered != isHovered else { return }
            isHovered = hovered
            hoverChanged?(hovered)
        }
        private var shouldCollapseSelectionOnMouseUp = false
        private var isForwardingMouseEvents = false

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = nil
            shouldCollapseSelectionOnMouseUp = false
            isForwardingMouseEvents = false

            let route = BrowserCellMouseDownRoute.resolve(
                modifierFlags: event.modifierFlags,
                usesNativeMouseTrackingWhenDragUnavailable:
                    usesNativeMouseTrackingWhenDragUnavailable,
                hasExporter: exporter != nil,
                hasDragWriter: dragWriter != nil,
                paneFocus: paneFocus
            )
            if route == .forwardToNativeView {
                isForwardingMouseEvents = true
                super.mouseDown(with: event)
                return
            }

            mouseDownPoint = convert(event.locationInWindow, from: nil)
            let modifiesSelection = event.modifierFlags.contains(.command)
                || event.modifierFlags.contains(.shift)
            shouldCollapseSelectionOnMouseUp = isSelected
                && selectionCount > 1
                && !modifiesSelection
            if !isSelected || modifiesSelection {
                select?(event.modifierFlags)
            }
            if BrowserEntryInteraction.isOpenClick(clickCount: event.clickCount) {
                open?()
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if isForwardingMouseEvents {
                super.mouseDragged(with: event)
                return
            }

            guard let mouseDownPoint,
                  let entry else { return }

            let currentPoint = convert(event.locationInWindow, from: nil)
            guard hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) > 3
            else { return }

            shouldCollapseSelectionOnMouseUp = false

            if let exporter {
                beginFilePromiseSession(with: event, entry: entry, currentPoint: currentPoint, exporter: exporter)
            } else if let dragWriter,
                      let writer = dragWriter(entry) {
                // The writer already aggregates the whole selection into one
                // payload item (dual-pane device → local drag).
                let item = NSDraggingItem(pasteboardWriter: writer)
                let origin = NSPoint(x: currentPoint.x - 16, y: currentPoint.y - 16)
                item.setDraggingFrame(
                    NSRect(origin: origin, size: NSSize(width: 32, height: 32)),
                    contents: makeDragImage(for: entry)
                )
                _ = beginDraggingSession(with: [item], event: event, source: self)
            } else {
                return
            }

            self.mouseDownPoint = nil
        }

        private func beginFilePromiseSession(
            with event: NSEvent,
            entry: BrowserEntry,
            currentPoint: NSPoint,
            exporter: @escaping (BrowserEntry, URL) async throws -> Void
        ) {
            let selectedEntries = selectedEntriesProvider()
            let draggedEntries: [BrowserEntry]
            if selectedEntries.contains(where: { $0.id == entry.id }) {
                draggedEntries = selectedEntries
            } else {
                draggedEntries = [entry]
            }

            let promiseDelegates = draggedEntries.map {
                DeviceFilePromiseDelegate(entry: $0, exporter: exporter)
            }
            let draggingItems = promiseDelegates.enumerated().map { index, delegate in
                let provider = delegate.makeProvider()
                let item = NSDraggingItem(pasteboardWriter: provider)
                let origin = NSPoint(
                    x: currentPoint.x - 16 + CGFloat(index * 3),
                    y: currentPoint.y - 16 - CGFloat(index * 3)
                )
                item.setDraggingFrame(
                    NSRect(origin: origin, size: NSSize(width: 32, height: 32)),
                    contents: delegate.dragImage
                )
                return item
            }

            _ = beginDraggingSession(with: draggingItems, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if isForwardingMouseEvents {
                super.mouseUp(with: event)
                resetMouseState()
                return
            }

            if shouldCollapseSelectionOnMouseUp {
                select?([])
            }
            resetMouseState()
        }

        private func resetMouseState() {
            mouseDownPoint = nil
            shouldCollapseSelectionOnMouseUp = false
            isForwardingMouseEvents = false
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }
    }
}

enum BrowserCellMouseDownRoute: Equatable {
    case forwardToNativeView
    case consume

    static func resolve(
        modifierFlags: NSEvent.ModifierFlags,
        usesNativeMouseTrackingWhenDragUnavailable: Bool,
        hasExporter: Bool,
        hasDragWriter: Bool,
        paneFocus: (() -> Void)?
    ) -> Self {
        paneFocus?()
        if modifierFlags.contains(.control)
            || (usesNativeMouseTrackingWhenDragUnavailable && !hasExporter && !hasDragWriter) {
            return .forwardToNativeView
        }
        return .consume
    }
}

@MainActor
final class DeviceFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let entry: BrowserEntry
    let exporter: (BrowserEntry, URL) async throws -> Void

    init(
        entry: BrowserEntry,
        exporter: @escaping (BrowserEntry, URL) async throws -> Void
    ) {
        self.entry = entry
        self.exporter = exporter
    }

    var fileTypeIdentifier: String {
        if entry.isDirectory {
            return UTType.folder.identifier
        }
        return UTType(filenameExtension: URL(fileURLWithPath: entry.name).pathExtension)?
            .identifier ?? UTType.data.identifier
    }

    var dragImage: NSImage {
        makeDragImage(for: entry)
    }

    func makeProvider() -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(
            fileType: fileTypeIdentifier,
            delegate: self
        )
        // NSFilePromiseProvider.delegate is weak. Finder may not request the
        // write until after AppKit ends the drag session, so the provider owns
        // the delegate until that asynchronous write completes.
        provider.userInfo = self
        return provider
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        entry.name
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let completion = CompletionBox(completionHandler)
        let providerBox = ProviderBox(filePromiseProvider)
        Task { @MainActor in
            defer { providerBox.releaseDelegate() }
            do {
                try await exporter(entry, url)
                completion.call(nil)
            } catch {
                completion.call(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }

    private final class CompletionBox: @unchecked Sendable {
        private let handler: ((any Error)?) -> Void

        init(_ handler: @escaping ((any Error)?) -> Void) {
            self.handler = handler
        }

        func call(_ error: (any Error)?) {
            handler(error)
        }
    }

    private final class ProviderBox: @unchecked Sendable {
        private let provider: NSFilePromiseProvider

        init(_ provider: NSFilePromiseProvider) {
            self.provider = provider
        }

        @MainActor
        func releaseDelegate() {
            // The delegate supplies .main as the promise operation queue, and
            // provider setup and teardown are both confined to MainActor.
            provider.userInfo = nil
        }
    }
}
