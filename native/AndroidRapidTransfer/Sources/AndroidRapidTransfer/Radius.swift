import SwiftUI

/// Corner radii shared across the app, so cards, rows and chips drawn by
/// different screens read as one family. Always with `.continuous` corners.
enum Radius {
    /// Cards and floating panels: help topics, shortcut groups, privacy
    /// sections, storage cards, the conflict comparison, the loading card,
    /// the drop target.
    static let card: CGFloat = 12
    /// Rows, grid cells and icon tiles inside a card or list.
    static let row: CGFloat = 8
    /// Small highlights and inset boxes: a menu row, a details box.
    static let small: CGFloat = 6
    /// A keycap.
    static let keycap: CGFloat = 5
}

extension View {
    /// The standard card: a secondary background, a hairline border and
    /// ``Radius/card`` corners.
    func cardSurface() -> some View {
        background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.background.secondary))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}
