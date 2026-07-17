import AndroidRapidTransferCore
import SwiftUI

struct CopyQueueRowView: View {
    let item: CopyQueueItem
    let remove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: TransferItemIcon.image(name: item.displayName, isDirectory: item.isDirectory))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
            }

            Spacer()

            Text(item.size.map { $0.formatted(.byteCount(style: .file)) } ?? "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(
                "Remove \(item.displayName) from copy queue",
                systemImage: "xmark.circle.fill",
                action: remove
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(isHovered ? Color.secondary : Color.secondary.opacity(0.5))
            .help("Remove from the queue")
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering in
            withMotion(Motion.snappy) { isHovered = hovering }
        }
    }
}
