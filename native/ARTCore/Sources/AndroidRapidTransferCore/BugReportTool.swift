import Foundation

/// Result of the device diagnostic in a bug report.
public struct DebugToolResult: Equatable, Sendable {
    public enum Termination: Equatable, Sendable {
        /// Every step ran without an error.
        case completed
        /// It finished, but a step failed or was skipped.
        case incomplete
        /// It overran its timeout and was cancelled.
        case timedOut(seconds: Int)
    }

    /// The diagnostic's name, as the report shows it.
    public let name: String
    /// Its output; nil when a timed-out diagnostic did not stop in time.
    public let report: String?
    public let termination: Termination

    public init(name: String, report: String?, termination: Termination) {
        self.name = name
        self.report = report
        self.termination = termination
    }

    /// The text written into the bundle. Every outcome produces a readable
    /// note rather than an absent file.
    public var reportText: String {
        var text = "Diagnostic: \(name)\nOutcome: \(Self.describe(termination))\n\n"
        text += report ?? "(no output: the diagnostic did not stop after it was cancelled)\n"
        return text
    }

    public var succeeded: Bool { termination == .completed }

    static func describe(_ termination: Termination) -> String {
        switch termination {
        case .completed:
            return "completed"
        case .incomplete:
            return "did not complete (see the errors in the summary)"
        case let .timedOut(seconds):
            return "timed out after \(seconds)s and was cancelled"
        }
    }
}

/// The device-level diagnostic in a bug report. Runs only while the app's
/// own device session is released.
public protocol DebugToolRunning: Sendable {
    /// The bundle file the result is written to, as the sheet lists it.
    var reportItem: BugReportItem { get }
    func run() async -> DebugToolResult
}

public extension BugReportItem {
    static let deviceDiagnostic = BugReportItem(
        fileName: "mtp-diagnostic.txt",
        description: "A read-only USB/MTP diagnostic of the phone: its USB interfaces, what it supports, its storages and how many items they hold at the top level"
    )
}
