import Foundation

/// The update behaviour produced by the user's settings for one build.
///
/// Mirrors the rules of the settings it replaces: background downloads only
/// run while automatic checks are on, and a prerelease build always follows
/// the beta channel (the switch is shown locked on) so a beta user keeps
/// receiving the betas they installed.
public struct UpdatePreferences: Equatable, Sendable {
    /// The Sparkle channel that beta releases are published to.
    public static let betaChannel = "beta"

    public let automaticallyChecks: Bool
    /// Effective value: never true while automatic checks are off.
    public let automaticallyDownloads: Bool
    /// Effective value: always true on a prerelease build.
    public let receivesBetaUpdates: Bool
    /// True on a prerelease build, where the beta switch cannot be turned off.
    public let isBetaChannelLocked: Bool

    public init(
        automaticallyChecks: Bool,
        automaticallyDownloads: Bool,
        receivesBetaUpdates: Bool,
        appVersion: String = AppVersion.current
    ) {
        let isPrerelease = AppVersion.isPrerelease(appVersion)
        self.automaticallyChecks = automaticallyChecks
        self.automaticallyDownloads = automaticallyChecks && automaticallyDownloads
        self.receivesBetaUpdates = isPrerelease || receivesBetaUpdates
        self.isBetaChannelLocked = isPrerelease
    }

    /// Channels the updater may find updates in, beyond the default channel.
    public var allowedChannels: Set<String> {
        receivesBetaUpdates ? [Self.betaChannel] : []
    }
}

/// Whether this process can run the updater at all.
///
/// Only a packaged `.app` that carries a feed URL and a public EdDSA key can
/// verify and install an update. Development runs (`swift run`, tests, a dev
/// bundle built without update keys) must not start one: Sparkle would show a
/// "failed to start" alert on every launch.
public enum UpdaterAvailability {
    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"

    public static func isAvailable(bundleURL: URL, infoDictionary: [String: Any]?) -> Bool {
        guard bundleURL.pathExtension == "app",
              let feed = infoDictionary?[feedURLKey] as? String,
              let feedURL = URL(string: feed),
              feedURL.scheme == "https",
              let key = infoDictionary?[publicKeyKey] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return true
    }
}

/// Holds an update's relaunch while copies are running.
///
/// Installing relaunches the app, and relaunching kills the device session and
/// every copy in flight. When the user chooses Install and Relaunch during a
/// transfer, the relaunch is parked here and released as soon as the last copy
/// finishes, instead of aborting the copies.
@MainActor
public final class UpdateInstallGate {
    private let hasActiveTransfers: () -> Bool
    private var pendingInstall: (() -> Void)?

    public init(hasActiveTransfers: @escaping () -> Bool) {
        self.hasActiveTransfers = hasActiveTransfers
    }

    public var isHoldingInstall: Bool {
        pendingInstall != nil
    }

    /// Returns true when the install must wait; `install` then runs later from
    /// ``transferActivityChanged()``. Returns false (and never calls `install`)
    /// when it may proceed now.
    public func shouldPostponeInstall(_ install: @escaping () -> Void) -> Bool {
        guard hasActiveTransfers() else { return false }
        pendingInstall = install
        return true
    }

    /// Call whenever transfer activity may have changed.
    public func transferActivityChanged() {
        guard let install = pendingInstall, !hasActiveTransfers() else { return }
        pendingInstall = nil
        install()
    }
}
