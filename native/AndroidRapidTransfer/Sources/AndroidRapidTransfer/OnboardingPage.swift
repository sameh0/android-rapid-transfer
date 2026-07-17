/// The onboarding sheet's pages, in order: a welcome, the three setup steps,
/// and a finish page.
enum OnboardingPage: Int, CaseIterable {
    case welcome
    case unlock
    case plugIn
    case fileTransfer
    case done

    /// Where Help › Connecting Your Phone… and the empty device pane start:
    /// the first setup step.
    static let connect = OnboardingPage.unlock

    var isFirst: Bool { self == .welcome }
    var isLast: Bool { self == .done }

    var next: Self? {
        Self(rawValue: rawValue + 1)
    }

    var previous: Self? {
        Self(rawValue: rawValue - 1)
    }

    /// The page's number among the setup steps (1-based), or nil for the
    /// welcome and finish pages.
    var setupStep: Int? {
        switch self {
        case .unlock: 1
        case .plugIn: 2
        case .fileTransfer: 3
        case .welcome, .done: nil
        }
    }

    static var setupStepCount: Int {
        allCases.count { $0.setupStep != nil }
    }
}
