import Foundation

/// How the transfer pipeline resolves duplicate/name conflicts when copying to a
/// destination that already holds an item with the same name.
public enum FileConflictPolicy: String, CaseIterable, Codable, Hashable, Sendable {
    /// Prompt for every conflicting file (the per-operation "apply to all"
    /// checkbox still short-circuits the rest of that operation). Default.
    case askEveryFile
    /// Prompt for the first conflict, then reuse that decision for every later
    /// conflict until the app relaunches.
    case askEverySession
    /// Skip every conflicting file without prompting.
    case alwaysSkip
    /// Overwrite every conflicting item without prompting.
    case alwaysOverwrite
}
