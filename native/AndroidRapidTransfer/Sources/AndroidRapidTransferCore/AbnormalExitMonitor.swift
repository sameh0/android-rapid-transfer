import Foundation
import Observation

/// Notices when the previous run ended without a clean quit.
///
/// A crash (a Swift runtime trap, or a signal from system code) cannot be
/// caught, so there is no way to show anything at the moment
/// it happens. Instead a marker file is written when a session starts and
/// removed on a clean quit; finding it at the next launch means the last session
/// ended abnormally, and the app can offer to help report it once.
public struct AbnormalExitMonitor: Sendable {
    public let markerURL: URL

    public init(markerURL: URL = Self.defaultMarkerURL()) {
        self.markerURL = markerURL
    }

    /// Next to the settings file (`AppSettings.defaultSettingsURL`), resolved
    /// the same way. Duplicated because `AppSettings` is main-actor isolated
    /// and this runs from the quit notification.
    public static func defaultMarkerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home: URL = if let value = environment["HOME"], !value.isEmpty {
            URL(fileURLWithPath: value, isDirectory: true)
        } else {
            .homeDirectory
        }
        return home.appending(path: "Library/Application Support/\(AppIdentity.supportDirectoryName)/session-running")
    }

    /// Records that a session has started.
    /// - Returns: `true` when the previous session did not end cleanly.
    @discardableResult
    public func beginSession(now: Date = Date()) -> Bool {
        let fileManager = FileManager.default
        let previousEndedAbnormally = fileManager.fileExists(atPath: markerURL.path)
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let contents = "pid \(ProcessInfo.processInfo.processIdentifier) started \(now.ISO8601Format())\n"
            try Data(contents.utf8).write(to: markerURL, options: .atomic)
        } catch {
            // Best effort: without a marker the next launch simply shows no notice.
        }
        return previousEndedAbnormally
    }

    /// Records a clean quit, so the next launch shows no notice.
    public func endSessionCleanly() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}

/// Whether this launch shows the "didn't quit normally" notice: at most once per
/// launch, and never again once dismissed.
@MainActor
@Observable
public final class AbnormalExitNotice {
    public private(set) var isVisible: Bool

    public init(previousSessionEndedAbnormally: Bool) {
        isVisible = previousSessionEndedAbnormally
    }

    public func dismiss() {
        isVisible = false
    }
}
