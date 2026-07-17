import Foundation

/// Releases the device session when the app quits.
///
/// Order matters: transfers are cancelled through the normal stop path first,
/// which aborts the file in flight (the provider cancels the MTP data phase),
/// and only then is the device released — ``DeviceConnectionController/releaseDevice()`` waits for
/// the transfer queue to drain before disposing the device session. The whole
/// sequence is bounded: quitting must never hang on a phone that stopped
/// answering, so after `timeout` the caller is told to proceed regardless.
public enum DeviceSessionShutdown {
    public enum Outcome: Equatable, Sendable {
        case completed
        case timedOut
    }

    public static let standardTimeout: Duration = .seconds(3)

    @MainActor
    public static func run(
        timeout: Duration = standardTimeout,
        stopTransfers: @escaping @MainActor () async -> Void,
        releaseDevice: @escaping @MainActor () async -> Void
    ) async -> Outcome {
        let gate = OutcomeGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            // Unstructured on purpose: a task group would wait for the work
            // even after the timeout fired, which is the hang this avoids.
            Task { @MainActor in
                await stopTransfers()
                await releaseDevice()
                gate.resolve(.completed)
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resolve(.timedOut)
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever side finishes first.
private final class OutcomeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DeviceSessionShutdown.Outcome, Never>?

    func install(_ continuation: CheckedContinuation<DeviceSessionShutdown.Outcome, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resolve(_ outcome: DeviceSessionShutdown.Outcome) {
        let pending = lock.withLock { () -> CheckedContinuation<DeviceSessionShutdown.Outcome, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: outcome)
    }
}
