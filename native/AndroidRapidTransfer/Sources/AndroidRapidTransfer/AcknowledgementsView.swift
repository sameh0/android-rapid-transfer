import AppKit
import AndroidRapidTransferCore
import SwiftUI

/// The third-party notices the app ships with. The text is long (full license
/// texts), so it is shown in an AppKit text view rather than SwiftUI `Text`,
/// which lays out and selects large bodies poorly.
struct AcknowledgementsView: View {
    private let text = Acknowledgements.text()

    var body: some View {
        if let text {
            VStack(alignment: .leading, spacing: 0) {
                SecondaryWindowHeader(
                    title: "Acknowledgements",
                    subtitle: "\(AppIdentity.name) is built with open-source software. Thank you to its authors.",
                    systemImage: "heart.fill"
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                Divider()
                AcknowledgementsTextView(text: text)
            }
        } else {
            ContentUnavailableView(
                "Acknowledgements Unavailable",
                systemImage: "doc.text",
                description: Text("The acknowledgements file is missing from this build.")
            )
        }
    }
}

private struct AcknowledgementsTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.string = text
        textView.setAccessibilityLabel(String(localized: "Acknowledgements"))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
