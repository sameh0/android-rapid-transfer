import Foundation

/// The user's well-known folders as the freedesktop.org `xdg-user-dirs` tool
/// records them in `$XDG_CONFIG_HOME/user-dirs.dirs` (localized names such as
/// `~/Schreibtisch` live there), with the conventional English folders as the
/// fallback. Used where Apple platforms have `URL.desktopDirectory` and friends.
public struct XDGUserDirectories: Sendable, Equatable {
    public let home: URL
    public let desktop: URL
    public let downloads: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        readFile: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) {
        let homePath = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: ".config", directoryHint: .isDirectory)
        let entries = readFile(configHome.appending(path: "user-dirs.dirs")).map(Self.parse) ?? [:]

        func resolve(_ key: String, _ fallback: String) -> URL {
            // A value equal to $HOME means the folder is disabled; use the fallback.
            if let value = entries[key] {
                let expanded = value.hasPrefix("$HOME")
                    ? homePath + value.dropFirst("$HOME".count)
                    : value
                if expanded.hasPrefix("/"),
                   URL(fileURLWithPath: expanded).standardizedFileURL != home.standardizedFileURL {
                    return URL(fileURLWithPath: expanded, isDirectory: true)
                }
            }
            return home.appending(path: fallback, directoryHint: .isDirectory)
        }

        self.home = home
        desktop = resolve("XDG_DESKTOP_DIR", "Desktop")
        downloads = resolve("XDG_DOWNLOAD_DIR", "Downloads")
    }

    /// Parses `KEY="value"` lines; comments and other lines are ignored.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            var value = String(line[line.index(after: equals)...])
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { continue }
            value = String(value.dropFirst().dropLast())
            result[key] = value.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return result
    }

    /// Where the desktop mounts removable disks: `/run/media/$USER` (udisks2's
    /// default) or `/media/$USER` (Debian and Ubuntu), else `/media`.
    public static func removableMediaRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> String {
        if let user = environment["USER"] ?? environment["LOGNAME"], !user.isEmpty {
            for candidate in ["/run/media/\(user)", "/media/\(user)"] where directoryExists(candidate) {
                return candidate
            }
        }
        return "/media"
    }
}
