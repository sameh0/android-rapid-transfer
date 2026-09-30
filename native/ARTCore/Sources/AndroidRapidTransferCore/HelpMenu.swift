import Foundation

/// Identifiers of the app's auxiliary windows, shared by the scene declarations
/// and every place that opens them.
public enum AppWindowID {
    public static let help = "help"
    public static let privacy = "privacy"
    public static let keyboardShortcuts = "keyboard-shortcuts"
    public static let reportBug = "report-bug"
    public static let resumeCopies = "resume-copies"
    public static let acknowledgements = "acknowledgements"
    public static let about = "about"

    public static let all = [help, privacy, keyboardShortcuts, reportBug, resumeCopies, acknowledgements, about]
}

/// The Help menu, in display order.
public enum HelpMenuItem: String, CaseIterable, Sendable {
    case troubleshooting
    case connectionHelp
    case keyboardShortcuts
    case onboarding
    case reportBug
    case privacy
    case acknowledgements

    public enum Destination: Equatable, Sendable {
        /// Opens the auxiliary window with this ``AppWindowID``.
        case window(String)
        /// Shows the onboarding sheet at its first setup step.
        case connectionOnboarding
        /// Shows the onboarding sheet from the start.
        case onboarding
    }

    public var title: String {
        switch self {
        case .troubleshooting: String(localized: "Troubleshooting & FAQ")
        case .connectionHelp: String(localized: "Connecting Your Phone…")
        case .keyboardShortcuts: String(localized: "Keyboard Shortcuts")
        case .onboarding: String(localized: "Getting Started")
        case .reportBug: String(localized: "Report a Bug…")
        case .privacy: String(localized: "Privacy")
        case .acknowledgements: String(localized: "Acknowledgements")
        }
    }

    public var destination: Destination {
        switch self {
        case .troubleshooting: .window(AppWindowID.help)
        case .connectionHelp: .connectionOnboarding
        case .keyboardShortcuts: .window(AppWindowID.keyboardShortcuts)
        case .onboarding: .onboarding
        case .reportBug: .window(AppWindowID.reportBug)
        case .privacy: .window(AppWindowID.privacy)
        case .acknowledgements: .window(AppWindowID.acknowledgements)
        }
    }

    /// Items after which the menu draws a divider.
    public var isFollowedByDivider: Bool {
        self == .onboarding
    }
}

/// Keyboard shortcuts grouped for help displays. Both the Keyboard Shortcuts
/// window and the inline help in the empty device pane read this, so they
/// always list the same shortcuts.
public struct ShortcutHelpGroup: Identifiable, Equatable, Sendable {
    public let scope: AppShortcut.Scope
    public let shortcuts: [AppShortcut]

    public var id: String { scope.rawValue }
}

public enum ShortcutHelp {
    public static func groups(
        from shortcuts: [AppShortcut] = AppShortcuts.helpListing
    ) -> [ShortcutHelpGroup] {
        AppShortcut.Scope.allCases.compactMap { scope in
            let matching = shortcuts.filter { $0.scope == scope }
            return matching.isEmpty ? nil : ShortcutHelpGroup(scope: scope, shortcuts: matching)
        }
    }
}
