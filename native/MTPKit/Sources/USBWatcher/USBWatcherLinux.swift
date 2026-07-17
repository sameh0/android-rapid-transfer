#if !os(macOS)
import Foundation

public enum USBWatcherError: Error, Equatable, Sendable {
    case notificationPortCreationFailed
}

/// Placeholder watcher for platforms without a hotplug backend yet: it starts
/// and stops cleanly but never emits events.
public final class USBWatcher: @unchecked Sendable {
    public let events: AsyncStream<USBDeviceEvent>
    private let continuation: AsyncStream<USBDeviceEvent>.Continuation

    public init() {
        let pair = AsyncStream<USBDeviceEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    deinit { continuation.finish() }

    public func start() throws {}
    public func stop() {}
}
#endif
