import Foundation

/// The app's identity. The user-facing name is read from the bundle so that a
/// rename touches the Info.plist and nothing else; user-visible copy should
/// interpolate ``name`` rather than spell the name out. The constants mirror
/// `Scripts/release-config.sh`, and a test keeps the two in step.
public enum AppIdentity {
    /// Used when the process has no bundle name, e.g. an unbundled `swift run`.
    public static let fallbackName = "Android Rapid Transfer"

    /// Who holds the copyright (LICENSE, the bundle's copyright line, About).
    /// Mirrors `COPYRIGHT_HOLDER` in `Scripts/release-config.sh`.
    public static let copyrightHolder = "Sameh"

    /// The release bundle identifier. Also the reverse-DNS prefix for the app's
    /// log subsystem, pasteboard types and Application Support directory, so
    /// that a development bundle (which appends `.dev` to its identifier)
    /// shares its settings and history with the release build.
    public static let bundleIdentifier = "com.sameh.AndroidRapidTransfer"

    /// The source repository, where releases, the update feed and issues live.
    public static let repositoryURL = URL(string: "https://github.com/sameh0/android-rapid-transfer")!

    public static var issuesURL: URL {
        repositoryURL.appending(path: "issues")
    }

    /// `~/Library/Application Support/<supportDirectoryName>`.
    public static let supportDirectoryName = bundleIdentifier

    /// A file-name-safe prefix for temporary and staging items the app creates.
    public static let fileNamePrefix = "AndroidRapidTransfer"

    public static var name: String {
        name(from: Bundle.main.infoDictionary)
    }

    public static func name(from info: [String: Any]?) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            guard let value = info?[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return fallbackName
    }

    /// The Application Support directory under `home`.
    public static func supportDirectory(home: URL) -> URL {
        home.appending(
            path: "Library/Application Support/\(supportDirectoryName)",
            directoryHint: .isDirectory
        )
    }
}
