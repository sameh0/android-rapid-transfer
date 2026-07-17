import Foundation

/// The stages of creating a bug report, in the order `BugReportGenerator`
/// runs them. The Report a Bug window ticks each one off as it completes.
public enum BugReportStage: Int, CaseIterable, Comparable, Sendable {
    /// Disconnecting the phone so the diagnostic can use it.
    case release
    /// Running the USB/MTP diagnostic, then reconnecting the phone.
    case diagnose
    /// Gathering the environment, log, settings and transfer history.
    case collect
    /// Writing the zip.
    case archive

    public var title: String {
        switch self {
        case .release: String(localized: "Disconnect the phone")
        case .diagnose: String(localized: "Run the USB diagnostic")
        case .collect: String(localized: "Collect logs and settings")
        case .archive: String(localized: "Create the zip")
        }
    }

    public var systemImage: String {
        switch self {
        case .release: "cable.connector.slash"
        case .diagnose: "stethoscope"
        case .collect: "doc.on.doc"
        case .archive: "doc.zipper"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
