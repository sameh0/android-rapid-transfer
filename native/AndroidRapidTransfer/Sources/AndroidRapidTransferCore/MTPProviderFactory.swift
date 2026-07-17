import Foundation
import MTPKit
import OSLog
import SwiftMTP

/// The one place that makes the device provider, used by the app and by every
/// device probe. Creating it touches no USB: the provider opens the phone on
/// first use.
public enum MTPProviderFactory {
    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "SwiftMTP")

    /// Routes the MTP engine's log into the app's log (and so into bug reports).
    public static let appLog: @Sendable (String) -> Void = { line in
        logger.info("\(line, privacy: .public)")
    }

    /// - Parameter log: the engine's diagnostic log; nil keeps it quiet.
    public static func make(log: (@Sendable (String) -> Void)? = appLog) -> any MTPDeviceProvider {
        SwiftMTPProvider(configuration: SwiftMTPProviderConfiguration(log: log))
    }
}
