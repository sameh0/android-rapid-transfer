import AndroidRapidTransferCore
import SwiftUI

struct KeyboardShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SecondaryWindowHeader(
                    title: "Keyboard Shortcuts",
                    subtitle: "Move around the browser and copy files without reaching for the mouse.",
                    systemImage: "keyboard.fill"
                )
                .padding(.bottom, 4)
                ForEach(Array(ShortcutHelp.groups().enumerated()), id: \.element.id) { index, group in
                    ShortcutGroupCard(group: group)
                        .staggeredAppearance(index: index + 1)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Splits a shortcut's display value ("⇧⌘N") into one keycap per key:
    /// each modifier symbol, then the key itself ("Delete" stays whole).
    nonisolated static func keycaps(for displayValue: String) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        let modifierPrefix = displayValue.prefix { modifiers.contains($0) }
        let key = displayValue.dropFirst(modifierPrefix.count)
        return modifierPrefix.map(String.init) + (key.isEmpty ? [] : [String(key)])
    }
}

private struct ShortcutGroupCard: View {
    let group: ShortcutHelpGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.scope.rawValue)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                if index > 0 {
                    Divider()
                        .padding(.leading, 14)
                }
                ShortcutRow(shortcut: shortcut)
            }
        }
        .padding(.bottom, 4)
        .cardSurface()
    }
}

private struct ShortcutRow: View {
    let shortcut: AppShortcut
    @State private var isHovered = false

    var body: some View {
        HStack {
            Text(shortcut.title)
            Spacer(minLength: 16)
            ShortcutKeycaps(displayValue: shortcut.displayValue, isPressed: isHovered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isHovered ? AnyShapeStyle(.tint.opacity(0.06)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
        .textSelection(.enabled)
    }
}

/// A shortcut drawn as a row of keycaps ("⇧", "⌘", "N"), the style every
/// shortcut list in the app shares. VoiceOver reads the shortcut as one value.
struct ShortcutKeycaps: View {
    let displayValue: String
    /// Dips the caps, as if pressed: pass the row's hover state.
    var isPressed = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(KeyboardShortcutsView.keycaps(for: displayValue).enumerated()), id: \.offset) { _, key in
                ShortcutKeycap(label: key, isPressed: isPressed)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(displayValue))
    }
}

/// A key drawn as a small raised cap; it dips when its row is hovered, as if
/// pressed.
private struct ShortcutKeycap: View {
    let label: String
    let isPressed: Bool

    var body: some View {
        Text(label)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, label.count > 1 ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(isPressed ? 0.08 : 0.2), radius: 0, y: isPressed ? 0.5 : 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous)
                    .strokeBorder(.separator)
            )
            .offset(y: isPressed ? 1 : 0)
    }
}
