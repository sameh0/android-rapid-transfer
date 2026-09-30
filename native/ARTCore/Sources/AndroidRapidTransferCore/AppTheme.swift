public enum AppTheme: String, CaseIterable, Codable, Hashable, Sendable {
    case system
    case light
    case dark

    public var appearanceOverride: AppAppearanceOverride? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}
