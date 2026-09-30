import Foundation

/// Name-based, scan-time exclusions for the date-range folder walk.
///
/// Every rule is a pure function of an entry's *name* — never of provider walk
/// flags — so a scan with every rule disabled is byte-identical to a scan that
/// predates this type. Skipped directories are pruned by the caller rather than
/// recursed into, which is the whole point: `Android/data` cache subtrees are
/// huge and slow to enumerate over MTP.
public struct ScanExclusionRules: Equatable, Sendable {
    /// Skips any entry (file or directory) whose name begins with `.`.
    public var ignoresDotFiles: Bool
    /// Skips cache-typical entries per ``cacheDirectoryNames`` and
    /// ``cacheFileSuffixes``.
    public var ignoresCacheFiles: Bool
    /// Lowercase file-name suffixes to skip, each with one leading dot (for
    /// example, `.cnt`). Directories are never matched against this set.
    public var ignoredExtensions: Set<String>

    /// No exclusions at all — the behaviour the scanner has always had.
    public static let none = ScanExclusionRules()

    public init(
        ignoresDotFiles: Bool = false,
        ignoresCacheFiles: Bool = false,
        ignoredExtensions: Set<String> = []
    ) {
        self.ignoresDotFiles = ignoresDotFiles
        self.ignoresCacheFiles = ignoresCacheFiles
        self.ignoredExtensions = ignoredExtensions
    }

    /// Directory names treated as caches, compared case-insensitively against
    /// the *whole* name — a directory merely containing "cache" in its name
    /// (e.g. `MyCachePhotos`) is deliberately kept.
    ///
    /// This is a heuristic, deliberately conservative: it names only the
    /// conventional Android/Linux cache directories rather than trying to guess.
    /// Extending it is a one-line change here. Entries must be lowercase.
    public static let cacheDirectoryNames: Set<String> = [
        "cache", ".cache", ".thumbnails", ".trash"
    ]

    /// Case-insensitive file-name suffixes treated as cache/temporary files.
    /// Part of the same conservative heuristic as ``cacheDirectoryNames``;
    /// extending it is a one-line change here. Entries must be lowercase and
    /// include the leading dot, so a file named exactly `.tmp` also matches.
    public static let cacheFileSuffixes: Set<String> = [".tmp"]

    /// `true` when the entry must be excluded from the scan.
    ///
    /// The caller applies this to every *discovered* entry and prunes skipped
    /// directories from the walk; explicitly selected scan roots are not
    /// filtered, because the user chose them by name on purpose.
    public func shouldSkip(name: String, isDirectory: Bool) -> Bool {
        if ignoresDotFiles, name.hasPrefix(".") {
            return true
        }
        if ignoresCacheFiles {
            let lowercased = name.lowercased()
            if isDirectory {
                return Self.cacheDirectoryNames.contains(lowercased)
            }
            if Self.cacheFileSuffixes.contains(where: lowercased.hasSuffix) {
                return true
            }
        }
        if !isDirectory, !ignoredExtensions.isEmpty {
            let lowercased = name.lowercased()
            return ignoredExtensions.contains(where: lowercased.hasSuffix)
        }
        return false
    }
}
