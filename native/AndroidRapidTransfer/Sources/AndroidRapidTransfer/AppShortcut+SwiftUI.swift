import AndroidRapidTransferCore
import SwiftUI

extension AppShortcut {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case let .character(character): KeyEquivalent(character)
        case .delete: .delete
        case .return: .return
        case .escape: .escape
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    func matches(_ keyPress: KeyPress) -> Bool {
        let relevantModifiers: EventModifiers = [.command, .shift, .option, .control]
        guard keyPress.modifiers.intersection(relevantModifiers) == eventModifiers else {
            return false
        }

        return switch key {
        case let .character(character):
            keyPress.characters.lowercased() == String(character).lowercased()
        case .delete:
            keyPress.key == .delete
        case .return:
            keyPress.key == .return
        case .escape:
            keyPress.key == .escape
        case .upArrow:
            keyPress.key == .upArrow
        case .downArrow:
            keyPress.key == .downArrow
        case .leftArrow:
            keyPress.key == .leftArrow
        case .rightArrow:
            keyPress.key == .rightArrow
        }
    }
}
