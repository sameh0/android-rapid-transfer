import AndroidRapidTransferCore
import SwiftUI

/// Connecting failed because of something on the Mac: another program or
/// driver holds the phone, or macOS refused to open its file transfer
/// interface. Says who and what to do; when the holder is macOS's Image
/// Capture service, offers to release the phone from it.
struct DeviceBlockedView: View {
    let presentation: ConnectionBlockedPresentation
    /// Why the last release did not work, if it did not.
    let releaseFailure: String?
    let isReleasing: Bool
    let release: () -> Void
    let retry: () -> Void
    let showConnectionHelp: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 18) {
            ConnectionMessageView(title: presentation.title, message: presentation.message)
            Text(presentation.guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if let releaseFailure {
                releaseFailureNote(releaseFailure)
                    .motionTransition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    if presentation.offersRelease {
                        releaseButton
                        ConnectionRetryButton(action: retry)
                            .disabled(isReleasing)
                    } else {
                        ConnectionRetryButton(isProminent: true, action: retry)
                    }
                }
                ConnectionHelpLinks(showConnectionHelp: showConnectionHelp)
            }
            DisclosureGroup("Details", isExpanded: detailsExpanded) {
                Text(presentation.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 380)
        }
        .motion(Motion.snappy, value: releaseFailure)
    }

    private var releaseButton: some View {
        Button(action: release) {
            Label {
                Text(isReleasing ? "Releasing…" : "Release the Phone")
            } icon: {
                if isReleasing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "eject")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isReleasing)
        .help("Stop macOS’s Image Capture service, which has the phone, then connect")
        .accessibilityLabel(isReleasing ? Text("Releasing the phone") : Text("Release the Phone"))
        .accessibilityHint("Stops macOS’s Image Capture service, which has the phone open, then connects. macOS starts the service again when an app needs it.")
    }

    private func releaseFailureNote(_ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }

    private var detailsExpanded: Binding<Bool> {
        Binding(
            get: { showsDetails },
            set: { expanded in withMotion(Motion.snappy) { showsDetails = expanded } }
        )
    }
}
