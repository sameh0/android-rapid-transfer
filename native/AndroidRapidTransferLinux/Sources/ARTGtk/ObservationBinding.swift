import CGtk
import Dispatch
import Observation

/// Where ``ObservationBinding`` delivers its re-runs.
@MainActor
public protocol UpdateScheduler: AnyObject {
    func schedule(_ work: @escaping @MainActor @Sendable () -> Void)
}

/// Delivers on the main queue, i.e. in the next GLib main-loop iteration via
/// ``MainLoopBridge``.
@MainActor
public final class MainQueueScheduler: UpdateScheduler {
    public static let shared = MainQueueScheduler()
    public init() {}

    public func schedule(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

/// Collects work until ``flush()`` (unit tests).
@MainActor
public final class ManualScheduler: UpdateScheduler {
    public private(set) var pending: [@MainActor @Sendable () -> Void] = []
    public init() {}

    public func schedule(_ work: @escaping @MainActor @Sendable () -> Void) { pending.append(work) }

    /// Runs everything scheduled so far (not work those runs schedule).
    public func flush() {
        let batch = pending
        pending.removeAll()
        batch.forEach { $0() }
    }
}

/// Re-runs a closure whenever `@Observable` properties it read change: the
/// Linux stand-in for SwiftUI's dependency tracking.
///
/// `body` runs once immediately under `withObservationTracking`. The first
/// change to anything it read schedules one re-run on the main actor (via the
/// scheduler, by default the next main-loop iteration); further changes before
/// that re-run are coalesced into it, because tracking is only re-registered
/// when the body runs again and reads the latest values. So a burst of
/// mutations costs one widget update per main-loop iteration.
///
/// Changes may come from any thread: the notification hops to the main actor.
///
///     let binding = ObservationBinding { label.text = model.status }
///     // or, tied to the widget's lifetime:
///     label.bind { $0.text = model.status }
@MainActor
public final class ObservationBinding {
    private let body: @MainActor () -> Void
    private let scheduler: any UpdateScheduler
    private var isScheduled = false
    public private(set) var isCancelled = false
    /// How many times the body has run (including the initial run).
    public private(set) var updateCount = 0

    public init(scheduler: any UpdateScheduler = MainQueueScheduler.shared, _ body: @escaping @MainActor () -> Void) {
        self.body = body
        self.scheduler = scheduler
        run()
    }

    /// Stops re-running. Also happens when the binding is released.
    public func cancel() { isCancelled = true }

    private func run() {
        isScheduled = false
        guard !isCancelled else { return }
        updateCount += 1
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            // Called synchronously from the mutated property's willSet, on the
            // mutating thread, at most once per registration.
            if art_is_main_thread().isTrue {
                MainActor.assumeIsolated { self?.scheduleRun() }
            } else {
                DispatchQueue.main.async { self?.scheduleRun() }
            }
        }
    }

    private func scheduleRun() {
        guard !isScheduled, !isCancelled else { return }
        isScheduled = true
        scheduler.schedule { [weak self] in self?.run() }
    }
}

/// Anything wrapping a GObject can own bindings.
@MainActor
public protocol BindingHost: GObjectRef {}
extension GObjectRef: BindingHost {}

extension BindingHost {
    /// Binds `update` to observable state for as long as this object lives.
    /// The object is passed in (and held weakly), so the closure need not
    /// capture it:
    ///
    ///     statusLabel.bind { $0.text = model.statusText }
    @discardableResult
    public func bind(_ update: @escaping @MainActor (Self) -> Void) -> ObservationBinding {
        let binding = ObservationBinding { [weak self] in
            guard let self else { return }
            update(self)
        }
        retainForLifetime(binding)
        return binding
    }
}
