import AndroidRapidTransferCore
import SwiftUI

/// One group of keyboard shortcuts, listed compactly (the empty device pane
/// uses it), with the same keycaps as the Keyboard Shortcuts window.
struct ShortcutScopeView: View {
    let group: ShortcutHelpGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.scope.rawValue)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(group.shortcuts) { shortcut in
                    ShortcutScopeRow(shortcut: shortcut)
                }
            }
        }
    }
}

private struct ShortcutScopeRow: View {
    let shortcut: AppShortcut
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Text(shortcut.title)
            Spacer(minLength: 16)
            ShortcutKeycaps(displayValue: shortcut.displayValue, isPressed: isHovered)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(.tint.opacity(isHovered ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .accessibilityElement(children: .combine)
    }
}
