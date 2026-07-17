import AndroidRapidTransferCore
import SwiftUI

/// Presentational grid icon. Mouse handling (select, double-click open,
/// hover, drag-out) lives in `BrowserCellMouseModifier` — a SwiftUI `Button`
/// with a simultaneous double-tap gesture loses most double-clicks on macOS.
struct BrowserGridCell: View {
    let entry: BrowserEntry
    let isSelected: Bool
    let isHovered: Bool
    /// Changes when this item should pop to draw the eye (just created or
    /// renamed); nil for every other item.
    let popTrigger: Int?
    let select: () -> Void
    /// Opens the item (a folder navigates, a file opens): VoiceOver's
    /// "Open" action, the double-click of the mouse path.
    var open: () -> Void = {}

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: BrowserEntryIcon.image(for: entry))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: BrowserEntryIcon.gridSize, height: BrowserEntryIcon.gridSize)
                // Hovering lifts the icon off the page a little.
                .scaleEffect(isLifted ? 1.06 : 1, anchor: .bottom)
                .shadow(
                    color: .black.opacity(isLifted ? 0.2 : 0),
                    radius: isLifted ? 5 : 0,
                    y: isLifted ? 3 : 0
                )
                .motionPop(trigger: popTrigger)
                .accessibilityHidden(true)
            Text(entry.name)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            Text(entry.formattedSize)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        // Top-aligned in a common height, so a one-line name does not push
        // its icon below the icons of two-line neighbours in the same row.
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .top)
        .padding(8)
        .background { background }
        .motion(Motion.snappy, value: isHovered)
        .motion(Motion.snappy, value: isSelected)
        .contentShape(.rect)
        .help(entry.name)
        .accessibilityLabel(entry.name)
        .accessibilityValue(entry.isDirectory ? "Folder" : entry.formattedSize)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityAction(named: "Open", open)
    }

    private var isLifted: Bool {
        isHovered && !isSelected
    }

    /// Selection springs in from slightly smaller; hover is a faint wash.
    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Color.primary.opacity(isHovered && !isSelected ? 0.05 : 0))
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                }
                .scaleEffect(isSelected ? 1 : 0.92)
                .opacity(isSelected ? 1 : 0)
        }
    }
}
