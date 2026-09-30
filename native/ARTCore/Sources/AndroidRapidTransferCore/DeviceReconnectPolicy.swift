import Foundation

/// How the connection controller reconnects on its own after the provider reports
/// that the device changed or vanished mid-session.
///
/// A phone re-enumerates for many reasons that are not a user unplugging it —
/// Android switching USB modes, a USB reset, a flaky cable — so after a
/// device-changed error the app reconnects rather than waiting for a manual
/// Retry. Attempts are bounded so a device that is really gone ends in "no
/// device" instead of an endless reconnect loop.
public struct DeviceReconnectPolicy: Equatable, Sendable {
    /// The wait before each attempt; its count is the attempt budget.
    public let delays: [Duration]
    /// A budget that has produced a successful connection is only replenished
    /// once this long has passed since its first attempt, so a device that
    /// connects and immediately drops again cannot loop faster than
    /// `delays.count` attempts per window.
    public let window: Duration

    public init(delays: [Duration], window: Duration) {
        self.delays = delays
        self.window = window
    }

    public static let standard = DeviceReconnectPolicy(
        delays: [
            .milliseconds(500), .seconds(1), .seconds(2),
            .seconds(3), .seconds(4), .seconds(5),
        ],
        window: .seconds(15)
    )

    public static let disabled = DeviceReconnectPolicy(delays: [], window: .zero)
}

/// Tracks one reconnect budget. A budget is never replenished by failures
/// alone, so a device that never comes back gets at most `delays.count`
/// attempts.
struct DeviceReconnectBudget {
    let policy: DeviceReconnectPolicy
    private(set) var attemptsUsed = 0
    private var windowStart: ContinuousClock.Instant?
    private var succeededSinceWindowStart = false

    init(policy: DeviceReconnectPolicy) {
        self.policy = policy
    }

    /// The delay before the next attempt, or `nil` when the budget is spent.
    mutating func nextDelay(now: ContinuousClock.Instant) -> Duration? {
        if let windowStart,
           succeededSinceWindowStart,
           windowStart.duration(to: now) >= policy.window {
            reset()
        }
        guard attemptsUsed < policy.delays.count else { return nil }
        if windowStart == nil {
            windowStart = now
            // Only a success inside this window may refill it. The connection
            // that preceded the loss must not count, or a phone that never
            // comes back gets the whole budget twice.
            succeededSinceWindowStart = false
        }
        let delay = policy.delays[attemptsUsed]
        attemptsUsed += 1
        return delay
    }

    mutating func recordSuccess() {
        succeededSinceWindowStart = true
    }

    mutating func reset() {
        attemptsUsed = 0
        windowStart = nil
        succeededSinceWindowStart = false
    }
}
