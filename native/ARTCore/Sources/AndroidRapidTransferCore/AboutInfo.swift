import Foundation

/// What the About window shows, read from the bundle's Info.plist so a
/// packaged build and an unbundled `swift run` both describe themselves
/// correctly.
public struct AboutInfo: Equatable, Sendable {
    public let name: String
    public let version: String
    /// `CFBundleVersion`; nil when running unbundled.
    public let build: String?
    public let copyright: String

    public init(info: [String: Any]?, version: String = AppVersion.current, now: Date = Date()) {
        name = AppIdentity.name(from: info)
        self.version = version
        build = Self.nonEmpty(info?["CFBundleVersion"] as? String)
        copyright = Self.nonEmpty(info?["NSHumanReadableCopyright"] as? String)
            ?? Self.fallbackCopyright(name: name, now: now)
    }

    public static var current: AboutInfo {
        AboutInfo(info: Bundle.main.infoDictionary)
    }

    /// "Version 0.2.0 (57)", or "Version 0.2.0 (development build)" unbundled.
    public var versionLine: String {
        let buildLabel = build ?? String(localized: "development build")
        return String(localized: "Version \(version) (\(buildLabel))")
    }

    /// One line identifying this build, for pasting into a bug report.
    public func diagnosticsLine(macOSVersion: String) -> String {
        "\(name) \(version) (\(build ?? "dev")), macOS \(macOSVersion)"
    }

    /// Mirrors `copyright_notice` in Scripts/release-config.sh.
    private static func fallbackCopyright(name: String, now: Date) -> String {
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        return "Copyright © \(year) \(AppIdentity.copyrightHolder)."
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
