import CGtk

/// The app's motion vocabulary on Linux, mirroring the macOS `Motion` tokens
/// (same names, same feel) as libadwaita spring and timing parameters.
///
/// Rules, as on macOS:
/// - Animate through ``Animation`` (or CSS transitions / `GtkRevealer` /
///   `GtkStack` transitions); they all honour the global animation switch
///   (`gtk-enable-animations`), and ``MotionPolicy`` adds the reduced-motion
///   preference.
/// - Never loop an animation directly: gate loops with ``MotionLiveness`` so
///   nothing ticks while the window is hidden, unfocused or idle.
public enum Motion {
    /// Spring parameters, built like SwiftUI's (response, damping fraction).
    public struct Spring: Sendable, Equatable {
        public let dampingRatio: Double
        public let mass: Double
        public let stiffness: Double

        public init(dampingRatio: Double, mass: Double = 1, stiffness: Double) {
            self.dampingRatio = dampingRatio
            self.mass = mass
            self.stiffness = stiffness
        }

        /// `response` is the undamped period in seconds.
        public init(response: Double, dampingRatio: Double, mass: Double = 1) {
            let omega = 2 * Double.pi / response
            self.init(dampingRatio: dampingRatio, mass: mass, stiffness: omega * omega * mass)
        }
    }

    /// Quick, critically damped: selection, hover, toggles, small layout changes.
    public static let snappy = Spring(response: Duration.standard, dampingRatio: 1)
    /// A little overshoot: things appearing, badges, drop targets accepting.
    public static let bouncy = Spring(response: Duration.slow, dampingRatio: 0.8)
    /// Slow and soft: panels, sheets' content, large layout moves.
    public static let gentle = Spring(response: Duration.slow, dampingRatio: 1)
    /// Playful, for moments worth marking (a batch copy finishing).
    public static let celebrate = Spring(response: 0.5, dampingRatio: 0.55)

    /// Standard durations, in seconds, for timed animations and transitions.
    public enum Duration {
        public static let quick: Double = 0.15
        public static let standard: Double = 0.25
        public static let slow: Double = 0.4
    }
}

/// What motion is allowed right now.
public struct MotionPolicy: Sendable, Equatable {
    /// GTK's global switch (`gtk-enable-animations`).
    public var animationsEnabled: Bool
    /// The desktop's reduced-motion preference (`gtk-interface-reduced-motion`).
    public var reduceMotion: Bool

    public init(animationsEnabled: Bool, reduceMotion: Bool) {
        self.animationsEnabled = animationsEnabled
        self.reduceMotion = reduceMotion
    }

    public var allowsMotion: Bool { animationsEnabled && !reduceMotion }

    /// `seconds`, or 0 when motion is off.
    public func duration(_ seconds: Double) -> Double { allowsMotion ? seconds : 0 }

    /// The desktop settings (GtkSettings of the default display).
    @MainActor
    public static var current: MotionPolicy {
        guard let settings = gtk_settings_get_default() else {
            return MotionPolicy(animationsEnabled: true, reduceMotion: false)
        }
        let p = UnsafeMutableRawPointer(settings)
        let enabled = art_object_get_bool(p, "gtk-enable-animations").isTrue
        var reduce = false
        if art_object_has_property(p, "gtk-interface-reduced-motion").isTrue {
            // 1 is GTK_REDUCED_MOTION_REDUCE; spelled as a number because the
            // enum only exists in GTK 4.22+ headers and this builds against older ones.
            reduce = art_object_get_int(p, "gtk-interface-reduced-motion") == 1
        }
        return MotionPolicy(animationsEnabled: enabled, reduceMotion: reduce)
    }
}

/// An `AdwAnimation` (spring or timed) driving a value.
///
///     Animation.spring(on: badge, .bouncy, from: 0.6, to: 1) { badge.opacity = $0 }.play()
///     Animation.spring(on: panel, .gentle, property: "opacity", from: 0, to: 1).play()
///
/// Animations run on the widget's frame clock, so they only tick while it is
/// mapped; with animations disabled or reduced motion they jump to the end.
@MainActor
public final class Animation: GObjectRef {
    public enum Easing: Sendable {
        case linear, easeOutCubic, easeInOutCubic, easeOutBack
        var adw: AdwEasing {
            switch self {
            case .linear: ADW_LINEAR
            case .easeOutCubic: ADW_EASE_OUT_CUBIC
            case .easeInOutCubic: ADW_EASE_IN_OUT_CUBIC
            case .easeOutBack: ADW_EASE_OUT_BACK
            }
        }
    }

    /// A spring driving `onValue`. An underdamped spring overshoots `to`
    /// unless `clamp` is set.
    public static func spring(on widget: Widget, _ spring: Motion.Spring, from: Double, to: Double, clamp: Bool = false,
                              _ onValue: @escaping @MainActor (Double) -> Void) -> Animation {
        let params = adw_spring_params_new(spring.dampingRatio, spring.mass, spring.stiffness)
        let p = adw_spring_animation_new(widget.widget, from, to, params, callbackTarget(onValue))!
        adw_spring_animation_set_clamp(UnsafeMutableRawPointer(p).cast(), clamp.gbool)
        return Animation(UnsafeMutableRawPointer(p))
    }

    /// Animates a numeric GObject property of `widget` (e.g. `"opacity"`).
    /// Clamped by default, since most properties reject values past their
    /// range (a bouncy spring would overshoot).
    public static func spring(on widget: Widget, _ spring: Motion.Spring, property: String, from: Double, to: Double,
                              clamp: Bool = true) -> Animation {
        let params = adw_spring_params_new(spring.dampingRatio, spring.mass, spring.stiffness)
        let target = adw_property_animation_target_new(widget.object, property)
        let p = adw_spring_animation_new(widget.widget, from, to, params, target)!
        adw_spring_animation_set_clamp(UnsafeMutableRawPointer(p).cast(), clamp.gbool)
        return Animation(UnsafeMutableRawPointer(p))
    }

    /// A timed animation. `repeatCount` 0 loops forever: only with
    /// ``MotionLiveness/drive(_:idleLoop:)``.
    public static func timed(on widget: Widget, duration: Double, from: Double, to: Double, easing: Easing = .easeOutCubic,
                             repeatCount: UInt32 = 1, alternate: Bool = false,
                             _ onValue: @escaping @MainActor (Double) -> Void) -> Animation {
        let p = adw_timed_animation_new(widget.widget, from, to, UInt32(duration * 1000), callbackTarget(onValue))!
        let raw = UnsafeMutableRawPointer(p)
        adw_timed_animation_set_easing(raw.cast(), easing.adw)
        adw_timed_animation_set_repeat_count(raw.cast(), repeatCount)
        adw_timed_animation_set_alternate(raw.cast(), alternate.gbool)
        return Animation(raw)
    }

    private static func callbackTarget(_ onValue: @escaping @MainActor (Double) -> Void) -> OpaquePointer? {
        adw_callback_animation_target_new({ value, data in
            let box = Boxed<@MainActor (Double) -> Void>.borrow(data!)
            onMain { box.value(value) }
        }, Boxed(onValue).retainedPointer(), releaseNotify)
    }

    /// Set while playing so a fire-and-forget animation outlives its caller's
    /// reference (`Animation.spring(…).play()`); cleared on `done`/`reset`.
    private var keepAliveWhilePlaying: Animation?
    private var watchesDone = false

    /// Plays, or jumps to the end when ``MotionPolicy`` disallows motion.
    /// The animation keeps itself alive until it finishes.
    public func play(policy: MotionPolicy = .current) {
        if !watchesDone {
            watchesDone = true
            connect("done") { [weak self] in self?.keepAliveWhilePlaying = nil }
        }
        if policy.allowsMotion {
            keepAliveWhilePlaying = self
            adw_animation_play(pointer.cast())
        } else {
            adw_animation_skip(pointer.cast())
        }
    }

    public func pause() { adw_animation_pause(pointer.cast()) }
    public func resume() { adw_animation_resume(pointer.cast()) }
    public func skip() { adw_animation_skip(pointer.cast()) }
    public func reset() {
        adw_animation_reset(pointer.cast())
        keepAliveWhilePlaying = nil
    }

    public var isPlaying: Bool { adw_animation_get_state(pointer.cast()) == ADW_ANIMATION_PLAYING }
    public var isPaused: Bool { adw_animation_get_state(pointer.cast()) == ADW_ANIMATION_PAUSED }
    public var value: Double { adw_animation_get_value(pointer.cast()) }

    public func onDone(_ body: @escaping @MainActor () -> Void) { connect("done", body) }
}

/// The Linux `motionIsLive` / `motionAllowsIdleLoops`: whether a window is
/// shown and focused, and whether the user touched it recently.
///
/// - ``isLive``: the window is visible, not suspended (minimized / off-screen)
///   and active.
/// - ``allowsIdleLoops``: live, and there was input within ``idleSettle``
///   seconds. Purely decorative loops use this so an idle window settles.
///
/// Idle detection costs nothing while idle: input only records a timestamp,
/// and a single one-shot timer re-arms itself while input keeps coming.
@MainActor
public final class MotionLiveness {
    public private(set) var isLive = false
    public private(set) var allowsIdleLoops = false
    public let idleSettle: Double

    private let windowRef: WeakObject
    private var lastActivity: gint64 = 0
    private var settleTimer: MainLoopTimer?
    private var observers: [@MainActor () -> Void] = []
    private var driven: [(animation: Animation, idleLoop: Bool)] = []

    public init(window: Window, idleSettle: Double = 12) {
        self.idleSettle = idleSettle
        windowRef = WeakObject(window.pointer)
        for property in ["is-active", "suspended", "visible"] {
            window.onNotify(property) { [weak self] in self?.recompute() }
        }
        window.onMap { [weak self] in self?.recompute() }
        window.onUnmap { [weak self] in self?.recompute() }
        for kind in [ActivityController.Kind.key, .motion, .scroll] {
            let controller = ActivityController(kind)
            controller.onActivity { [weak self] in self?.noteActivity() }
            window.add(controller)
        }
        noteActivity()
        recompute()
    }

    /// Runs `body` whenever ``isLive`` or ``allowsIdleLoops`` changes.
    public func onChange(_ body: @escaping @MainActor () -> Void) { observers.append(body) }

    /// Plays `animation` (a loop) only while allowed, pausing it otherwise.
    public func drive(_ animation: Animation, idleLoop: Bool = false) {
        driven.append((animation, idleLoop))
        apply()
    }

    public func stopDriving(_ animation: Animation) {
        driven.removeAll { $0.animation === animation }
    }

    /// Records user input (also called by the window's input controllers).
    public func noteActivity() {
        lastActivity = g_get_monotonic_time()
        if settleTimer == nil { armSettleTimer(after: idleSettle) }
        recompute()
    }

    private func armSettleTimer(after seconds: Double) {
        settleTimer = MainLoopTimer.after(seconds) { [weak self] in
            guard let self else { return }
            self.settleTimer = nil
            let idleFor = Double(g_get_monotonic_time() - self.lastActivity) / 1_000_000
            if idleFor < self.idleSettle { self.armSettleTimer(after: self.idleSettle - idleFor) }
            self.recompute()
        }
    }

    private func recompute() {
        let live = windowRef.withObject { p in
            gtk_widget_get_mapped(p.cast()).isTrue && gtk_widget_get_visible(p.cast()).isTrue
                && !gtk_window_is_suspended(p.cast()).isTrue && gtk_window_is_active(p.cast()).isTrue
        } ?? false
        let recentlyUsed = Double(g_get_monotonic_time() - lastActivity) / 1_000_000 < idleSettle
        let idle = live && recentlyUsed
        guard live != isLive || idle != allowsIdleLoops else { return }
        isLive = live
        allowsIdleLoops = idle
        apply()
        observers.forEach { $0() }
    }

    private func apply() {
        let policy = MotionPolicy.current
        for (animation, idleLoop) in driven {
            let allowed = policy.allowsMotion && (idleLoop ? allowsIdleLoops : isLive)
            if allowed {
                if animation.isPaused { animation.resume() } else if !animation.isPlaying { animation.play(policy: policy) }
            } else if animation.isPlaying {
                animation.pause()
            }
        }
    }
}
