import AppKit
import AndroidRapidTransferCore

/// The slice of `NSWorkspace` the browser uses, so tests never launch apps
/// or open Finder windows.
@MainActor
protocol WorkspaceActions {
    func open(_ url: URL) -> Bool
    func activateFileViewerSelecting(_ fileURLs: [URL])
}

extension NSWorkspace: WorkspaceActions {}

/// The slice of `NSPasteboard` "Copy Path" writes to.
@MainActor
protocol StringPasteboard {
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: StringPasteboard {}

/// Opens local files in their default application.
struct WorkspaceFileOpener: LocalFileOpening {
    var workspace: any WorkspaceActions = NSWorkspace.shared

    func open(_ url: URL) {
        _ = workspace.open(url)
    }
}

@MainActor
enum BrowserSystemActions {
    /// Selects the items in Finder, in their enclosing folder.
    static func revealInFinder(
        _ urls: [URL],
        workspace: any WorkspaceActions = NSWorkspace.shared
    ) {
        guard !urls.isEmpty else { return }
        workspace.activateFileViewerSelecting(urls)
    }

    /// One path per line, the way Finder's "Copy as Pathname" does.
    static func copyPaths(
        _ paths: [String],
        to pasteboard: any StringPasteboard = NSPasteboard.general
    ) {
        guard !paths.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }
}

extension BrowserPaneModel {
    func revealInFinder(_ selection: Set<BrowserEntry.ID>) {
        BrowserSystemActions.revealInFinder(revealableURLs(for: selection))
    }

    func copyPaths(_ selection: Set<BrowserEntry.ID>) {
        BrowserSystemActions.copyPaths(copyablePaths(for: selection))
    }
}
