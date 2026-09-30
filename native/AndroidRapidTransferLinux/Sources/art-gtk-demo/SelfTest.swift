import ARTGtk
import CGtk
import Dispatch
import Glibc
import Observation

/// `art-gtk-demo --self-test`: automated checks against the real GTK loop.
/// Prints one `CHECK` line per check and `VERIFICATION ok` when all pass;
/// exits non-zero otherwise.
@MainActor
final class SelfTest {
    let app: Application
    private var failures: [String] = []
    private var passed = 0
    private var window: Window?

    init(app: Application) { self.app = app }

    func start() {
        // Watchdog: a hung check must not hang CI.
        let watchdog = MainLoopTimer.after(90) {
            print("FAILED: self-test timed out")
            exit(2)
        }
        Task { @MainActor in
            await run()
            watchdog.cancel()
            if failures.isEmpty {
                print("VERIFICATION ok (\(passed) checks)")
                exitStatus = 0
            } else {
                print("FAILED: \(failures.count) of \(passed + failures.count) checks: \(failures.joined(separator: "; "))")
                exitStatus = 1
            }
            window?.destroy()
            window = nil
            app.quit()
        }
    }

    private(set) var exitStatus: Int32 = 1

    private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("CHECK ok   \(name)")
        } else {
            let text = "\(name)\(detail().isEmpty ? "" : " (\(detail()))")"
            failures.append(text)
            print("CHECK FAIL \(text)")
        }
    }

    /// Suspends until `condition` holds (polling via Task.sleep, which itself
    /// resumes through the bridge) or `timeout` passes.
    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = g_get_monotonic_time() + gint64(timeout * 1_000_000)
        while !condition() {
            if g_get_monotonic_time() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Resumes after everything already queued on the main queue has run.
    private func nextMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func run() async {
        let window = Window()
        window.title = "ARTGtk self-test"
        window.setDefaultSize(width: 900, height: 600)
        self.window = window
        await checkBridge()
        await checkObservation()
        await checkListModel(window: window)
        await checkActions()
        await checkClosureRelease()
        await checkAlert(window: window)
        await checkMotion(window: window)
        await checkIdle()
    }

    // MARK: Main-actor bridge

    private func checkBridge() async {
        check("bridge installed", MainLoopBridge.isInstalled)
        check("running inside the GLib main loop", g_main_depth() > 0, "depth \(g_main_depth())")

        // DispatchQueue.main.async: FIFO, main thread, dispatched from a GLib source.
        var order: [Int] = []
        var allOnMain = true
        var depths: [Int32] = []
        for index in 0..<200 {
            DispatchQueue.main.async {
                order.append(index)
                allOnMain = allOnMain && MainLoopBridge.isMainThread
                depths.append(g_main_depth())
            }
        }
        _ = await waitUntil { order.count == 200 }
        check("DispatchQueue.main.async runs in FIFO order", order == Array(0..<200), "\(order.count) ran")
        check("DispatchQueue.main.async runs on the main thread", allOnMain)
        check("main-queue work is dispatched from a GLib source", depths.allSatisfy { $0 > 0 })

        // Task { @MainActor }: runs after the current job, in order.
        var log: [String] = []
        Task { @MainActor in log.append("task1") }
        Task { @MainActor in log.append("task2") }
        log.append("sync")
        _ = await waitUntil { log.count == 3 }
        check("Task { @MainActor } runs after the current job, in order", log == ["sync", "task1", "task2"], "\(log)")

        // Detached task hopping back with MainActor.run.
        let hop = await Task.detached { () -> (Bool, Bool) in
            let offMain = !MainLoopBridge.isMainThread
            let onMain = await MainActor.run { MainLoopBridge.isMainThread }
            return (offMain, onMain)
        }.value
        check("detached task runs off the main thread", hop.0)
        check("await MainActor.run from a detached task lands on the main thread", hop.1)

        // A global queue posting to the main queue.
        let fromGlobal = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                DispatchQueue.main.async { continuation.resume(returning: MainLoopBridge.isMainThread) }
            }
        }
        check("global queue → DispatchQueue.main.async lands on the main thread", fromGlobal)

        // Task.sleep then a main-actor UI update.
        let label = Label("before")
        let started = g_get_monotonic_time()
        try? await Task.sleep(for: .milliseconds(120))
        label.text = "after"
        let sleptMs = Double(g_get_monotonic_time() - started) / 1000
        check("Task.sleep resumes on the main actor and updates a widget", label.text == "after" && MainLoopBridge.isMainThread)
        check("Task.sleep(120 ms) takes ~120 ms", sleptMs >= 115 && sleptMs < 600, "\(Int(sleptMs)) ms")

        // Main-actor continuations resumed from a background thread.
        let value = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            Thread.detachNew { continuation.resume(returning: 42) }
        }
        check("continuation resumed on a background thread returns to the main actor", value == 42 && MainLoopBridge.isMainThread)
    }

    // MARK: Observation

    private func checkObservation() async {
        let model = ObservedCounter()
        let label = Label()
        var runs = 0
        label.bind { label in
            runs += 1
            label.text = "\(model.a)-\(model.b)-\(model.c)"
        }
        check("binding runs immediately", runs == 1 && label.text == "0-0-0", "runs \(runs) text \(label.text)")

        for step in 1...5 {
            model.a = step
            model.b = step * 10
            model.c = step * 100
        }
        check("binding does not run synchronously on mutation", runs == 1, "runs \(runs)")
        await nextMainQueueTurn()
        check("15 mutations coalesce into one update per loop iteration", runs == 2, "runs \(runs)")
        check("coalesced update sees the final values", label.text == "5-50-500", label.text)

        model.untracked = 99
        await nextMainQueueTurn()
        check("changing an unread property does not re-run", runs == 2, "runs \(runs)")

        // Mutation from a background thread hops to the main actor.
        var ranOnMain = true
        let threadLabel = Label()
        threadLabel.bind { label in
            ranOnMain = ranOnMain && MainLoopBridge.isMainThread
            label.text = "\(model.a)"
        }
        await Task.detached { model.a = 777 }.value
        let updated = await waitUntil { threadLabel.text == "777" }
        check("background mutation updates the widget on the main thread", updated && ranOnMain, threadLabel.text)

        // Bindings die with their widget.
        let weakBinding: WeakBox<ObservationBinding>
        do {
            let temp = Label()
            weakBinding = WeakBox(temp.bind { $0.text = "\(model.b)" })
        }
        check("binding is released with its widget", weakBinding.value == nil)
    }

    // MARK: Lists

    private func checkListModel(window: Window) async {
        let rows = FileRow.sample(count: 10_000)
        let table = FileTable(rows: rows)
        let pipeline = table.view.pipeline
        window.setChild(ScrolledWindow(table.view).expand(h: true, v: true))
        let frames = FrameCounter(table.view)
        window.present()
        let ticking = await waitUntil(timeout: 5) { frames.count > 2 }
        check("window receives frames (needs a presenting display: not a locked/off screen)", ticking, "\(frames.count) frames")

        check("column view has 10,000 rows", pipeline.visibleCount == 10_000, "\(pipeline.visibleCount)")
        _ = await waitUntil { table.nameFactory.liveCells > 0 }
        try? await Task.sleep(for: .milliseconds(300))
        let cells = table.nameFactory.liveCells
        check("cells are created lazily and recycled (not one per row)", cells > 0 && cells < 400, "\(cells) name cells, window mapped \(window.isMapped) suspended \(window.isSuspended), table \(table.view.width)x\(table.view.height)")

        table.view.sort(by: table.sizeColumn, ascending: false)
        let maxSize = rows.map(\.size).max()!
        check("sorting by size (descending) puts the largest first", pipeline.item(at: 0)?.size == maxSize)
        table.view.sort(by: table.nameColumn, ascending: true)
        check("sorting by name puts folders first", pipeline.item(at: 0)?.isFolder == true)

        table.store.remove(at: 0)
        check("remove updates the view model", pipeline.visibleCount == 9_999 && table.store.count == 9_999)
        table.store.append(FileRow(id: 99_999, name: "zzz-appended.txt", isFolder: false, size: 1, modified: 0))
        check("append updates the view model", pipeline.visibleCount == 10_000)
        table.store.update(at: 10, with: FileRow(id: 10, name: "renamed.txt", isFolder: false, size: 5, modified: 0))
        check("update replaces one row", table.store[10].name == "renamed.txt" && pipeline.visibleCount == 10_000)
        table.store.remove(at: [1, 2, 3])
        check("multi-remove", table.store.count == 9_997 && pipeline.visibleCount == 9_997)

        pipeline.filter.update { $0.lowercasedName.contains("vid_") }
        let expected = table.store.items.filter { $0.lowercasedName.contains("vid_") }.count
        check("filter shows only matching rows", pipeline.visibleCount == expected, "\(pipeline.visibleCount) vs \(expected)")
        pipeline.filter.update { _ in true }
        check("clearing the filter restores all rows", pipeline.visibleCount == 9_997)

        pipeline.selection.select(0)
        pipeline.selection.select(5, exclusive: false)
        check("multi-selection reports positions", pipeline.selection.selectedPositions == [0, 5], "\(pipeline.selection.selectedPositions)")
        table.store.replaceAll([])
        check("replaceAll([]) empties the view", pipeline.visibleCount == 0)
        window.setChild(nil)
    }

    // MARK: Actions

    private func checkActions() async {
        var activated = 0
        app.addAction("selftest-ping") { activated += 1 }
        app.setAccelerators(["<Control><Shift>p"], for: "app.selftest-ping")
        g_action_group_activate_action(app.pointer.cast(), "selftest-ping", nil)
        check("app action activates its closure", activated == 1)
        let accels = gtk_application_get_accels_for_action(app.pointer.cast(), "app.selftest-ping")
        let first = accels.flatMap { $0.pointee }.map { String(cString: $0) }
        g_strfreev(accels)
        check("accelerator registered", first == "<Shift><Control>p" || first == "<Control><Shift>p", first ?? "nil")

        var toggled: [Bool] = []
        let toggle = SimpleAction("selftest-toggle", state: false) { toggled.append($0) }
        app.add(toggle)
        toggle.activate()
        toggle.activate()
        check("toggle action flips its state", toggled == [true, false] && toggle.boolState == false, "\(toggled)")
        app.removeAction("selftest-ping")
        app.removeAction("selftest-toggle")
    }

    // MARK: Lifetimes

    private func checkClosureRelease() async {
        let clickFlag = Flag()
        let bindFlag = Flag()
        let disconnectFlag = Flag()
        var clicked = false
        let buttonGone: WeakObject
        let windowGone: WeakObject
        do {
            let window = Window()
            let button = Button("Press")
            let label = Label()
            let sentinel = Sentinel(clickFlag)
            button.onClicked {
                _ = sentinel
                clicked = true
            }
            let bindSentinel = Sentinel(bindFlag)
            label.bind { $0.text = bindSentinel.name }
            let disconnectSentinel = Sentinel(disconnectFlag)
            let connection = label.connect("map") { _ = disconnectSentinel }
            connection.disconnect()
            window.setChild(Box(.vertical, spacing: 0, [button, label]))
            window.present()
            button.emit("clicked")
            buttonGone = WeakObject(button.pointer)
            windowGone = WeakObject(window.pointer)
            window.destroy()
        }
        check("signal closure ran", clicked)
        check("disconnect releases the closure immediately", disconnectFlag.value)
        _ = await waitUntil(timeout: 2) { clickFlag.value && bindFlag.value }
        check("window and widgets are finalized after destroy", windowGone.isGone && buttonGone.isGone)
        check("signal closures are released when the widget is destroyed", clickFlag.value)
        check("bindings are released when the widget is destroyed", bindFlag.value)
    }

    // MARK: Dialogs

    private func checkAlert(window: Window) async {
        let alert = AlertDialog(heading: "Self-test", body: "Closing automatically.")
        alert.addResponse("cancel", "Cancel")
        alert.addResponse("ok", "OK", appearance: .suggested)
        alert.closeResponse = "cancel"
        let timer = MainLoopTimer.after(0.3) { alert.close() }
        let response = await alert.choose(parent: window)
        _ = timer
        check("alert dialog returns its close response asynchronously", response == "cancel", response)

        let overlay = ToastOverlay(Label("toast host"))
        window.setChild(overlay)
        let toast = overlay.show("Self-test toast", timeout: 1)
        var dismissed = false
        toast.onDismissed { dismissed = true }
        toast.dismiss()
        check("toast can be shown and dismissed", dismissed)
        window.setChild(nil)
    }

    // MARK: Motion

    private func checkMotion(window: Window) async {
        let label = Label("motion")
        window.setChild(label)
        try? await Task.sleep(for: .milliseconds(100))
        var last = -1.0
        var done = false
        var values = 0
        let frames = FrameCounter(label)
        let animation = Animation.spring(on: label, Motion.snappy, from: 0, to: 1) { last = $0; values += 1 }
        animation.onDone { done = true }
        animation.play()
        let finished = await waitUntil(timeout: 3) { done }
        let policy = MotionPolicy.current
        check("spring animation finishes at its target", finished && abs(last - 1) < 0.001,
              "done \(done) last \(last) values \(values) frames \(frames.count) frameTimeSpan \(frames.lastTime - frames.firstTime) µs playing \(animation.isPlaying) animations \(policy.animationsEnabled)")

        let liveness = MotionLiveness(window: window, idleSettle: 0.3)
        let loop = Animation.timed(on: label, duration: 1, from: 0, to: 1, repeatCount: 0) { _ in }
        liveness.drive(loop, idleLoop: true)
        let settled = await waitUntil(timeout: 3) { !liveness.allowsIdleLoops }
        check("idle loops settle after the idle period and are paused", settled && !loop.isPlaying,
              "live \(liveness.isLive) idle \(liveness.allowsIdleLoops) playing \(loop.isPlaying)")
        liveness.stopDriving(loop)
        window.setChild(nil)
    }

    // MARK: Idle

    private func checkIdle() async {
        try? await Task.sleep(for: .milliseconds(200))
        let drainsBefore = MainLoopBridge.drains
        var usageBefore = rusage()
        getrusage(RUSAGE_SELF.rawValue, &usageBefore)
        let wall = g_get_monotonic_time()
        try? await Task.sleep(for: .seconds(2))
        var usageAfter = rusage()
        getrusage(RUSAGE_SELF.rawValue, &usageAfter)
        let cpu = cpuSeconds(usageAfter) - cpuSeconds(usageBefore)
        let elapsed = Double(g_get_monotonic_time() - wall) / 1_000_000
        let drains = MainLoopBridge.drains - drainsBefore
        check("idle: the main queue is not polled (≤ 2 drains in 2 s)", drains <= 2, "\(drains) drains")
        check("idle: CPU < 2% over 2 s", cpu / elapsed < 0.02, "\(Int(cpu * 1000)) ms CPU in \(Int(elapsed * 1000)) ms")
    }

    private func cpuSeconds(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
}

/// A model mutated from any thread (Observation's registrar is thread-safe).
@Observable
final class ObservedCounter: @unchecked Sendable {
    var a = 0
    var b = 0
    var c = 0
    var untracked = 0
}

/// Counts frame-clock ticks of a widget (a direct GTK tick callback).
@MainActor
final class FrameCounter {
    private(set) var count = 0
    private(set) var firstTime: Int64 = 0
    private(set) var lastTime: Int64 = 0

    init(_ widget: Widget) {
        let me = Unmanaged.passRetained(self).toOpaque()
        gtk_widget_add_tick_callback(widget.widget, { _, clock, data in
            let counter = Unmanaged<FrameCounter>.fromOpaque(data!).takeUnretainedValue()
            let time = Int64(gdk_frame_clock_get_frame_time(clock))
            MainActor.assumeIsolated {
                if counter.count == 0 { counter.firstTime = time }
                counter.lastTime = time
                counter.count += 1
            }
            return 1 // G_SOURCE_CONTINUE
        }, me, { data in Unmanaged<FrameCounter>.fromOpaque(data!).release() })
    }
}

final class Flag: @unchecked Sendable {
    var value = false
}

final class Sentinel {
    let flag: Flag
    let name = "sentinel"
    init(_ flag: Flag) { self.flag = flag }
    deinit { flag.value = true }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// A plain OS thread (no Foundation).
enum Thread {
    static func detachNew(_ body: @escaping @Sendable () -> Void) {
        final class Payload { let body: @Sendable () -> Void; init(_ b: @escaping @Sendable () -> Void) { body = b } }
        var thread = pthread_t()
        let payload = Unmanaged.passRetained(Payload(body)).toOpaque()
        pthread_create(&thread, nil, { raw in
            let payload = Unmanaged<Payload>.fromOpaque(raw!).takeRetainedValue()
            payload.body()
            return nil
        }, payload)
        pthread_detach(thread)
    }
}
