import AndroidRapidTransferCore
import SwiftUI

/// Asks what to do when a copy would land on an existing item. The two items
/// sit side by side — the one already there and the one being copied — and
/// pointing at a choice, or moving keyboard focus to it, previews its
/// outcome: Replace fades the existing item, Skip fades the incoming one,
/// Keep Both keeps both lit.
struct FileConflictDialogView: View {
    let prompt: FileConflictPrompt
    let resolve: (FileConflictResolution, Bool) -> Void
    @State private var appliesToAll = false
    @State private var hovered: FileConflictResolution?
    @FocusState private var focused: FileConflictResolution?

    /// The choice being previewed: the one under the pointer, else the one
    /// with keyboard focus.
    private var previewed: FileConflictResolution? {
        hovered ?? focused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(prompt.fileName)” already exists")
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("in \(destinationName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(prompt.destination)
                }
            }

            HStack(spacing: 10) {
                FileConflictCard(
                    caption: "Already there",
                    name: prompt.fileName,
                    item: prompt.existing,
                    badge: badge(for: prompt.existing, against: prompt.incoming),
                    isDimmed: previewed == .replace
                )
                Image(systemName: arrowSymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                FileConflictCard(
                    caption: "Copying",
                    name: prompt.fileName,
                    item: prompt.incoming,
                    badge: badge(for: prompt.incoming, against: prompt.existing),
                    isDimmed: previewed == .skip
                )
            }
            .motion(Motion.snappy, value: previewed)

            Text(outcomeText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .motion(Motion.fade, value: previewed)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("Do the same for every conflict in this copy", isOn: $appliesToAll)

            HStack {
                choice("Skip", .skip)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                choice("Keep Both", .keepBoth)
                    .keyboardShortcut(.defaultAction)
                choice("Replace", .replace, role: .destructive)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private func choice(
        _ title: String,
        _ resolution: FileConflictResolution,
        role: ButtonRole? = nil
    ) -> some View {
        Button(title, role: role) {
            resolve(resolution, appliesToAll)
        }
        .focused($focused, equals: resolution)
        .onHover { hovering in
            if hovering {
                hovered = resolution
            } else if hovered == resolution {
                hovered = nil
            }
        }
        .help(help(for: resolution))
    }

    private var destinationName: String {
        let name = URL(fileURLWithPath: prompt.destination).lastPathComponent
        return name.isEmpty || name == "/" ? "the top folder" : "“\(name)”"
    }

    private var arrowSymbol: String {
        switch previewed {
        case .skip: "xmark"
        case .keepBoth: "plus"
        case .replace, nil: "arrow.left"
        }
    }

    private var outcomeText: String {
        switch previewed {
        case .replace: "Replace overwrites the item that’s already there."
        case .skip: "Skip leaves the existing item alone and doesn’t copy this one."
        case .keepBoth: "Keep Both copies this one with a number added to its name."
        case nil: "Point at a choice, or Tab to it, to see what it does."
        }
    }

    private func help(for resolution: FileConflictResolution) -> String {
        switch resolution {
        case .replace: "Overwrite the existing item"
        case .skip: "Don’t copy this item"
        case .keepBoth: "Copy it with a number added to its name"
        }
    }

    /// "Newer" / "Larger" on the side that wins the comparison, so the
    /// decision can be made at a glance.
    private func badge(for item: FileConflictItem?, against other: FileConflictItem?) -> String? {
        guard let item, let other else { return nil }
        switch item.comparison(to: other) {
        case .newer: return "Newer"
        case .larger: return "Larger"
        case .sameSize: return "Same size"
        case .older, .smaller, .unknown: return nil
        }
    }
}

/// One side of the comparison: Finder's icon, the name, where it lives, its
/// size and date, and an optional highlight badge.
private struct FileConflictCard: View {
    let caption: String
    let name: String
    let item: FileConflictItem?
    let badge: String?
    let isDimmed: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(caption.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Image(nsImage: TransferItemIcon.image(name: name, isDirectory: item?.isDirectory ?? false))
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            if let location = item?.location {
                Label(location == .mac ? "On this Mac" : "On the phone",
                      systemImage: location == .mac ? "laptopcomputer" : "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 1) {
                Text(sizeText)
                    .monospacedDigit()
                Text(dateText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // Always laid out, so both cards keep the same height.
            Text(badge ?? " ")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: .capsule)
                .foregroundStyle(Color.accentColor)
                .opacity(badge == nil ? 0 : 1)
                .accessibilityHidden(badge == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(.separator)
        }
        .opacity(isDimmed ? 0.4 : 1)
        .scaleEffect(isDimmed ? 0.97 : 1)
        .accessibilityElement(children: .combine)
    }

    private var sizeText: String {
        guard let item else { return "Size unknown" }
        if item.isDirectory { return "Folder" }
        return item.size.map { $0.formatted(.byteCount(style: .file)) } ?? "Size unknown"
    }

    private var dateText: String {
        guard let modified = item?.modified else { return "Date unknown" }
        return modified.formatted(date: .abbreviated, time: .shortened)
    }
}
