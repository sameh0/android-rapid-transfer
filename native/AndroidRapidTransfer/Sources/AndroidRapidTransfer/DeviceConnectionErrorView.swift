import SwiftUI

/// Connecting failed for a reason that is not "no phone" or "replug it".
/// Leads with what to do; the error itself is one click away under Details,
/// for bug reports and searching.
struct DeviceConnectionErrorView: View {
    let message: String
    let retryable: Bool
    let retry: () -> Void
    let showConnectionHelp: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 18) {
            ConnectionMessageView(
                title: "Couldn’t connect to the phone",
                message: "Check that the cable is firmly plugged in and the phone is unlocked, then try again."
            )
            VStack(spacing: 10) {
                if retryable {
                    ConnectionRetryButton(isProminent: true, action: retry)
                }
                ConnectionHelpLinks(showConnectionHelp: showConnectionHelp)
            }
            DisclosureGroup("Details", isExpanded: detailsExpanded) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 380)
        }
    }

    private var detailsExpanded: Binding<Bool> {
        Binding(
            get: { showsDetails },
            set: { expanded in withMotion(Motion.snappy) { showsDetails = expanded } }
        )
    }
}
