import Foundation

/// Where the app keeps its own files on Linux, following the XDG Base
/// Directory specification: settings under `$XDG_CONFIG_HOME`, runtime state
/// (the session marker) under `$XDG_STATE_HOME` and saved batch copies under
/// `$XDG_DATA_HOME`, each in a folder named after the app id. Relative or
/// empty variables are ignored, as the specification requires.
public struct XDGAppDirectories: Sendable, Equatable {
    /// `$XDG_CONFIG_HOME/<id>`, by default `~/.config/<id>`.
    public let config: URL
    /// `$XDG_STATE_HOME/<id>`, by default `~/.local/state/<id>`.
    public let state: URL
    /// `$XDG_DATA_HOME/<id>`, by default `~/.local/share/<id>`.
    public let data: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directoryName: String = AppIdentity.supportDirectoryName
    ) {
        let homePath = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let home = URL(fileURLWithPath: homePath, isDirectory: true)

        func base(_ variable: String, _ fallback: String) -> URL {
            if let value = environment[variable], value.hasPrefix("/") {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return home.appending(path: fallback, directoryHint: .isDirectory)
        }

        config = base("XDG_CONFIG_HOME", ".config").appending(path: directoryName, directoryHint: .isDirectory)
        state = base("XDG_STATE_HOME", ".local/state").appending(path: directoryName, directoryHint: .isDirectory)
        data = base("XDG_DATA_HOME", ".local/share").appending(path: directoryName, directoryHint: .isDirectory)
    }
}
