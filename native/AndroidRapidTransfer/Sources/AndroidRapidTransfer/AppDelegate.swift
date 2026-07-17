import AndroidRapidTransferCore
import AppKit

/// Lets the app release the device before it exits. The policy — cancel
/// transfers, release the session, never take longer than a few seconds —
/// lives in `DeviceSessionShutdown` so it is testable; this only defers the
/// quit until it has run. Also gives an unbundled run the app icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Installed by `AndroidRapidTransferApp` once its models exist.
    static var prepareForTermination: (@MainActor () async -> Void)?

    private var isTerminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        installIconIfUnbundled()
    }

    /// A packaged app takes its icon from Contents/Resources/AppIcon.icns. An
    /// unbundled `swift run` has none, so it draws the same artwork for the
    /// Dock and the About window.
    private func installIconIfUnbundled() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
              let image = AppIconArtwork.image(pixels: 512)
        else { return }
        NSApplication.shared.applicationIconImage = NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepare = Self.prepareForTermination else { return .terminateNow }
        // A repeated Quit while the first is still releasing the device must
        // not start a second release; the pending reply completes the quit.
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        Task { @MainActor in
            await prepare()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
