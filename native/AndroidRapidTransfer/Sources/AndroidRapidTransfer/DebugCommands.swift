import MTPKit
import AndroidRapidTransferCore
import SwiftUI

#if DEBUG
struct DebugCommands: Commands {
    let provider: MockMTPProvider
    let controller: DeviceConnectionController

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Simulate Device Browse Failure", action: simulateBrowseFailure)
        }
    }

    private func simulateBrowseFailure() {
        Task { @MainActor in
            await provider.scriptFailure(.listDirectory, for: .walk)
            await controller.deviceModel?.refresh()
        }
    }
}

/// Development only: plugs the `--demo` phone in and out (see ``DemoMode``).
struct DemoCommands: Commands {
    let session: DemoDeviceSession

    var body: some Commands {
        CommandMenu("Demo") {
            Button("Plug In Demo Phone") { session.plugIn() }
                .keyboardShortcut("p", modifiers: [.command, .option, .control])
            Button("Unplug Demo Phone") { session.unplug() }
                .keyboardShortcut("u", modifiers: [.command, .option, .control])
        }
    }
}
#endif
