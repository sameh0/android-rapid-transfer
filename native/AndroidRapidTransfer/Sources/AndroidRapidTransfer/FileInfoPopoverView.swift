import AndroidRapidTransferCore
import SwiftUI

struct FileInfoPopoverView: View {
    let entry: BrowserEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: BrowserEntryIcon.image(for: entry))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(kind)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            LabeledContent("Size", value: entry.formattedSize)
            LabeledContent("Modified", value: entry.formattedModifiedDate)
            LabeledContent("Path") {
                Text(entry.location)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(idealWidth: 360)
    }

    private var kind: String {
        if entry.isDirectory { return "Folder" }
        return BrowserEntryIcon.contentType(for: entry).localizedDescription ?? "Document"
    }
}
