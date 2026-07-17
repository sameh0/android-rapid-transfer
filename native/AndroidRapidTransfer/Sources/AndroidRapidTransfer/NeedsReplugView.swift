import SwiftUI

/// The phone's MTP session is wedged and only a physical replug clears it.
/// The illustration above demonstrates the gesture.
struct NeedsReplugView: View {
    let deviceName: String?
    let message: String?
    let allowsManualRetry: Bool
    let retry: () -> Void
    let showConnectionHelp: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ConnectionMessageView(
                title: "Unplug and reconnect your phone",
                message: message ?? description
            )
            VStack(spacing: 10) {
                if allowsManualRetry {
                    ConnectionRetryButton(action: retry)
                }
                ConnectionHelpLinks(showConnectionHelp: showConnectionHelp)
            }
        }
    }

    private var description: String {
        if let deviceName {
            "Unplug \(deviceName), then plug it back in to start a fresh connection."
        } else {
            "Unplug the phone, then plug it back in to start a fresh connection."
        }
    }
}
