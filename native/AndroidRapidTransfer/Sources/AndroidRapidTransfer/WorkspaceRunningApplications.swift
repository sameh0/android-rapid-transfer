import AndroidRapidTransferCore
import AppKit
import UniformTypeIdentifiers

/// Running apps from `NSWorkspace`, for ``ConflictingAppsModel``.
///
/// Quitting uses `NSRunningApplication.terminate()`, the polite request ⌘Q
/// sends; it needs a non-sandboxed app, which this is.
@MainActor
final class WorkspaceRunningApplications: RunningApplicationsProviding {
    private let workspace: NSWorkspace
    private var notificationObservers: [NSObjectProtocol] = []
    private var runningApplicationsObservation: NSKeyValueObservation?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    var runningApplications: [RunningAppSnapshot] {
        workspace.runningApplications.compactMap { app in
            guard !app.isTerminated else { return nil }
            return RunningAppSnapshot(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                name: app.localizedName
            )
        }
    }

    func terminate(processIdentifier: Int32) -> Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?.terminate() ?? false
    }

    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void) {
        stopObserving()
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: workspace, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
            notificationObservers.append(observer)
        }
        // The launch and quit notifications skip background and menu bar apps
        // (cloud sync clients among them); the running-apps list itself is
        // key-value observable and covers every app.
        runningApplicationsObservation = workspace.observe(\.runningApplications) { _, _ in
            Task { @MainActor in onChange() }
        }
    }

    func stopObserving() {
        let center = workspace.notificationCenter
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
        runningApplicationsObservation?.invalidate()
        runningApplicationsObservation = nil
    }

    /// The app's icon, or the generic app icon once it has quit.
    static func icon(forProcessIdentifier pid: Int32) -> NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// Brings the app forward, so a save prompt holding up its quit can be answered.
    static func activate(processIdentifier pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
