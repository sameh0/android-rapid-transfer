import Foundation

/// Third-party notices the app must ship with. The full text lives in
/// `Resources/Acknowledgements.txt`, which the packaging scripts copy into
/// `Contents/Resources`; update it and ``components`` whenever a dependency is
/// added, removed or upgraded.
public enum Acknowledgements {
    /// One bundled third-party component.
    public struct Component: Equatable, Sendable {
        /// The name as it appears in the text's component list.
        public let name: String
        /// The license as it appears in the text's component list.
        public let license: String
    }

    public static let resourceName = "Acknowledgements"
    public static let resourceExtension = "txt"

    /// Stands in for the app's name, which is read from the bundle at load time.
    static let appNamePlaceholder = "{{APP_NAME}}"

    /// What the app ships besides its own code and Apple's frameworks.
    public static let components: [Component] = [
        Component(name: "Sparkle 2.10.0", license: "MIT License"),
    ]

    /// The acknowledgements with the app's name filled in, or `nil` if the
    /// text can't be found.
    public static func text(bundle: Bundle = .main, appName: String = AppIdentity.name) -> String? {
        guard let url = resourceURL(in: bundle),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return raw.replacingOccurrences(of: appNamePlaceholder, with: appName)
    }

    static func resourceURL(in bundle: Bundle) -> URL? {
        if let bundled = bundle.url(forResource: resourceName, withExtension: resourceExtension) {
            return bundled
        }
        #if DEBUG
        // `swift run` and tests have no app bundle; read the source file.
        let source = sourceURL
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// `native/AndroidRapidTransfer/Resources/Acknowledgements.txt`, found from this file.
    static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AndroidRapidTransferCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // native/AndroidRapidTransfer
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(resourceName).\(resourceExtension)")
    }
    #endif
}
