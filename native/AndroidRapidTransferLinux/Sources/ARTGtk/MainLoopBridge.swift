import CGtk
import Dispatch
import Glibc

/// Drives Swift's main actor and `DispatchQueue.main` from the GLib main loop.
///
/// ## Why this exists
///
/// On Linux, Swift's main actor enqueues its jobs on libdispatch's main queue
/// (the default main executor is dispatch-based), and so does
/// `DispatchQueue.main.async`. That queue only runs when something drains it:
/// `dispatchMain()` or CoreFoundation's run loop. A GTK app instead spends its
/// life inside `g_application_run`, i.e. the GLib main loop, so without a
/// bridge `Task { @MainActor in … }`, `await MainActor.run { … }`, main-actor
/// continuations after `await`, and `DispatchQueue.main.async` would never run.
///
/// ## How
///
/// libdispatch exposes the two hooks CoreFoundation uses to integrate its run
/// loop with the main queue (`*_4CF`, "for CoreFoundation"):
///
/// - `_dispatch_get_main_queue_handle_4CF()` returns the main queue's wake-up
///   handle, on Linux an `eventfd`. libdispatch writes to it whenever work is
///   enqueued on an idle main queue.
/// - `_dispatch_main_queue_callback_4CF(nil)` drains the main queue; it must
///   be called on the main thread.
///
/// ``install()`` watches that eventfd with a GLib unix-fd source
/// (`g_unix_fd_add`). When it becomes readable, GLib calls us on the main
/// thread during a normal loop iteration; we reset the eventfd counter (the
/// fd is non-blocking) and then drain the queue. Anything enqueued while
/// draining writes the eventfd again, so it is picked up next iteration.
/// There are no timers and no polling: an idle app sleeps in `poll(2)` with
/// the eventfd in its fd set, so idle CPU stays at zero.
///
/// Call ``install()`` once, on the main thread, before `g_application_run`
/// (``Application/run(arguments:)`` does it for you). It is idempotent.
public enum MainLoopBridge {
    nonisolated(unsafe) private static var sourceID: guint = 0
    nonisolated(unsafe) private static var drainCount: UInt64 = 0

    /// Installs the bridge on the default GLib main context. Main thread only.
    public static func install() {
        precondition(isMainThread, "MainLoopBridge.install() must run on the main thread")
        guard sourceID == 0 else { return }
        let fd = _dispatch_get_main_queue_handle_4CF()
        precondition(fd >= 0, "libdispatch returned no main-queue handle")
        sourceID = g_unix_fd_add(fd, G_IO_IN, { fd, _, _ in
            // Reset the eventfd counter first, then drain, so that work queued
            // during the drain signals the fd again rather than being lost.
            var counter: UInt64 = 0
            _ = read(fd, &counter, MemoryLayout<UInt64>.size)
            MainLoopBridge.drainCount &+= 1
            _dispatch_main_queue_callback_4CF(nil)
            return gboolean(1) // G_SOURCE_CONTINUE
        }, nil)
    }

    /// Whether ``install()`` has run.
    public static var isInstalled: Bool { sourceID != 0 }

    /// How many times the main queue has been drained from the GLib loop
    /// (diagnostics and the self-test's idle check).
    public static var drains: UInt64 { drainCount }

    /// Whether the caller is on the process's main thread.
    public static var isMainThread: Bool { art_is_main_thread() != 0 }

    /// Runs one non-blocking iteration of the default GLib main context
    /// (tests and self-checks that need to pump the loop manually).
    @discardableResult
    public static func iterate(mayBlock: Bool = false) -> Bool {
        g_main_context_iteration(nil, mayBlock ? 1 : 0) != 0
    }

    /// Pumps the GLib loop (and therefore the main actor) until `condition`
    /// is true or `timeout` seconds pass. Returns whether the condition held.
    @MainActor
    public static func spin(timeout: Double, until condition: () -> Bool) -> Bool {
        let deadline = g_get_monotonic_time() + gint64(timeout * 1_000_000)
        while !condition() {
            if g_get_monotonic_time() > deadline { return false }
            // A 10 ms timeout source keeps the blocking iteration bounded.
            let timer = g_timeout_add(10, { _ in gboolean(0) }, nil)
            g_main_context_iteration(nil, 1)
            if g_main_context_find_source_by_id(nil, timer) != nil { g_source_remove(timer) }
        }
        return true
    }
}

/// A one-shot or repeating GLib timeout that runs a main-actor closure.
/// Cancelled when released or by ``cancel()``. Prefer one-shot timers:
/// a repeating one wakes the process even when nothing changes.
@MainActor
public final class MainLoopTimer {
    private var sourceID: guint = 0

    private init() {}

    /// Runs `body` once after `seconds`.
    public static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> MainLoopTimer {
        make(seconds, repeats: false, body)
    }

    /// Runs `body` every `seconds` until cancelled or released.
    public static func every(_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> MainLoopTimer {
        make(seconds, repeats: true, body)
    }

    private static func make(_ seconds: Double, repeats: Bool, _ body: @escaping @MainActor () -> Void) -> MainLoopTimer {
        let timer = MainLoopTimer()
        let weakTimer = Weak(timer)
        let box = Boxed<@MainActor () -> Bool>({
            body()
            if !repeats { weakTimer.value?.sourceID = 0 }
            return repeats
        })
        timer.sourceID = g_timeout_add_full(G_PRIORITY_DEFAULT, guint(max(0, seconds) * 1000), { data in
            let box = Boxed<@MainActor () -> Bool>.borrow(data!)
            return onMain { box.value() }.gbool
        }, box.retainedPointer(), releaseNotify)
        return timer
    }

    public var isActive: Bool { sourceID != 0 }

    public func cancel() {
        if sourceID != 0 { g_source_remove(sourceID) }
        sourceID = 0
    }

    deinit {
        if sourceID != 0 { g_source_remove(sourceID) }
    }
}
