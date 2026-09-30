import Foundation

public struct AppShortcut: Identifiable, Hashable, Sendable {
    public enum ID: String, Hashable, Sendable {
        case newFolder
        case refresh
        case addToCopyQueue
        case copySelection
        case pasteQueue
        case switchPane
        case goUp
        case rename
        case selectAll
        case deleteSelection
        case openSelection
        case clearSelection
        case previousListItem
        case nextListItem
        case previousGridItem
        case nextGridItem
        case extendToPreviousListItem
        case extendToNextListItem
        case extendToPreviousGridItem
        case extendToNextGridItem
    }

    public enum Key: Hashable, Sendable {
        case character(Character)
        case delete
        case `return`
        case escape
        case upArrow
        case downArrow
        case leftArrow
        case rightArrow
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let command = Self(rawValue: 1 << 0)
        public static let shift = Self(rawValue: 1 << 1)
        public static let option = Self(rawValue: 1 << 2)
        public static let control = Self(rawValue: 1 << 3)
    }

    public enum Scope: String, CaseIterable, Sendable {
        case app = "App"
        case browser = "File Browser"
    }

    public let id: ID
    public let title: String
    public let key: Key
    public let modifiers: Modifiers
    public let scope: Scope

    public init(
        id: ID,
        title: String,
        key: Key,
        modifiers: Modifiers = [],
        scope: Scope
    ) {
        self.id = id
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
    }

    public var displayValue: String {
        modifierSymbols + key.displayValue
    }

    private var modifierSymbols: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }
}

private extension AppShortcut.Key {
    var displayValue: String {
        switch self {
        case let .character(character): String(character).uppercased()
        case .delete: "Delete"
        case .return: "Return"
        case .escape: "Esc"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        }
    }
}
