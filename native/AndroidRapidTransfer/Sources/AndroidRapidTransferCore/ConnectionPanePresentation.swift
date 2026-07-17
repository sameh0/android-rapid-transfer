import Foundation

/// What the device pane shows for the connection controller's published
/// state: one case per screen. The view animates between them, so the mapping
/// lives here where tests can pin it down.
public enum ConnectionPanePhase: Equatable, Sendable {
    /// No phone and nothing in progress. `notice` says why, when the
    /// disconnection was not the user's doing (including a reconnect that gave up).
    case waiting(notice: String?)
    case detecting
    case reconnecting(ConnectionReconnectProgress)
    case connected
    case needsReplug(deviceName: String?, message: String?)
    case failed(message: String, retryable: Bool)

    /// The screen, without its details: what transitions are keyed on, so a
    /// new attempt number updates the reconnect screen in place instead of
    /// replacing it.
    public enum Kind: Hashable, Sendable {
        case waiting, detecting, reconnecting, connected, needsReplug, failed
    }

    public init(
        state: DeviceConnectionController.State,
        isReconnecting: Bool,
        hasDeviceModel: Bool,
        notice: String?,
        reconnectProgress: ConnectionReconnectProgress
    ) {
        switch state {
        case .noDevice, .detecting:
            if isReconnecting {
                self = .reconnecting(reconnectProgress)
            } else if state == .detecting {
                self = .detecting
            } else {
                self = .waiting(notice: notice)
            }
        case .connected:
            // The browser model is created with the connected state; until it
            // exists there is nothing to browse yet.
            self = hasDeviceModel ? .connected : .detecting
        case let .needsReplug(deviceName, message):
            self = .needsReplug(deviceName: deviceName, message: message)
        case let .error(message, retryable):
            self = .failed(message: message, retryable: retryable)
        }
    }

    public var kind: Kind {
        switch self {
        case .waiting: .waiting
        case .detecting: .detecting
        case .reconnecting: .reconnecting
        case .connected: .connected
        case .needsReplug: .needsReplug
        case .failed: .failed
        }
    }
}

/// How far an automatic reconnect sequence has got, for the reconnect screen's
/// progress ring: the attempt ``DeviceConnectionController`` reports, out of
/// its budget, and whether that attempt is running right now.
public struct ConnectionReconnectProgress: Equatable, Sendable {
    /// The most attempts one sequence makes (``DeviceReconnectPolicy``).
    public let limit: Int
    /// The attempt running or last run in the current sequence; 0 while
    /// waiting for the first.
    public let attempt: Int
    /// Whether an attempt is running right now, rather than waiting out the
    /// delay before the next one.
    public let isAttempting: Bool

    public init(attempt: Int = 0, limit: Int = DeviceReconnectPolicy.standard.delays.count, isAttempting: Bool = false) {
        self.limit = max(0, limit)
        self.attempt = min(max(0, attempt), self.limit)
        self.isAttempting = isAttempting && self.attempt > 0
    }

    /// The controller's reconnect sequence as it stands.
    @MainActor
    public init(controller: DeviceConnectionController) {
        self.init(
            attempt: controller.isReconnecting ? controller.reconnectAttempt : 0,
            limit: controller.reconnectAttemptLimit,
            isAttempting: controller.isReconnecting && controller.state == .detecting
        )
    }

    /// The share of the budget spent, from 0 to 1.
    public var fraction: Double {
        guard limit > 0 else { return 0 }
        return Double(attempt) / Double(limit)
    }
}

/// The "connected" moment shown briefly when a phone's files are ready.
public struct ConnectionArrival: Equatable, Sendable {
    public let deviceName: String
    /// Free space on the storage the browser opened, when the phone reports it.
    public let freeBytes: Int64?
    public let isReconnect: Bool

    public init(deviceName: String, freeBytes: Int64?, isReconnect: Bool) {
        self.deviceName = deviceName
        self.freeBytes = freeBytes
        self.isReconnect = isReconnect
    }

    public var title: String {
        isReconnect
            ? String(localized: "Reconnected to \(deviceName)")
            : String(localized: "\(deviceName) connected")
    }
}

/// How full a storage is, for the colour of its capacity bar.
public enum StorageUsageLevel: Equatable, Sendable {
    case normal
    /// 90% used or more.
    case nearlyFull
    /// 98% used or more: copies to the phone are likely to fail.
    case full

    public init(usedFraction: Double) {
        switch usedFraction {
        case 0.98...: self = .full
        case 0.9...: self = .nearlyFull
        default: self = .normal
        }
    }
}

public extension DeviceStorage {
    /// The used share of the storage, clamped to 0...1, or nil when the phone
    /// did not report a capacity.
    var usedFraction: Double? {
        guard let totalBytes, let freeBytes, totalBytes > 0 else { return nil }
        let used = Double(totalBytes - min(max(freeBytes, 0), totalBytes))
        return min(max(used / Double(totalBytes), 0), 1)
    }

    var usageLevel: StorageUsageLevel? {
        usedFraction.map(StorageUsageLevel.init(usedFraction:))
    }

    /// Whether the storage looks like a memory card or other removable
    /// volume. MTP storage types are unreliable across phones, so this reads
    /// the name the phone gives it.
    var isRemovable: Bool {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { ["sd", "sdcard", "microsd", "card", "usb", "otg", "external"].contains($0) }
    }
}
