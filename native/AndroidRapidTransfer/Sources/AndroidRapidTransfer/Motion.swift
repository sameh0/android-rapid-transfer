import AppKit
import SwiftUI

/// The app's shared animation vocabulary. Use these tokens instead of ad hoc
/// springs and durations so motion feels the same everywhere, and animate
/// through the helpers below so that everything collapses to an instant change
/// when the user has turned on System Settings › Accessibility › Display ›
/// Reduce motion.
///
/// In views:
///
///     content
///         .motion(.snappy, value: isExpanded)          // implicit animation
///         .motionTransition(.move(edge: .bottom))      // insert/remove
///
///     Button("Show") { withMotion(.gentle) { isShown = true } }
///
/// `withMotion` and ``MotionPolicy/current`` read the system setting directly
/// (`NSWorkspace`), so they also work outside a view; view modifiers read
/// `accessibilityReduceMotion` from the environment.
enum Motion {
    /// Quick, critically damped: selection, hover, toggles, small layout changes.
    static let snappy = Animation.snappy(duration: Duration.standard)
    /// A little overshoot: things appearing, badges, drop targets accepting.
    static let bouncy = Animation.bouncy(duration: Duration.slow, extraBounce: 0.05)
    /// Slow and soft: panels, sheets' content, large layout moves.
    static let gentle = Animation.smooth(duration: Duration.slow)
    /// Playful, reserved for moments worth marking (a batch copy finishing).
    static let celebrate = Animation.spring(response: 0.5, dampingFraction: 0.55)
    /// A plain cross-fade.
    static let fade = Animation.easeInOut(duration: Duration.quick)

    /// A panel docked to the window's bottom edge (the transfer panel)
    /// sliding in and out. Pair it with ``gentle``.
    static var panelSlide: AnyTransition { .move(edge: .bottom).combined(with: .opacity) }

    /// Standard durations, in seconds, for timing that is not an `Animation`
    /// (delays, `DispatchQueue` hand-offs, AppKit animation contexts). Pass
    /// them through ``MotionPolicy/duration(_:)`` so Reduce Motion zeroes them.
    enum Duration {
        static let quick: TimeInterval = 0.15
        static let standard: TimeInterval = 0.25
        static let slow: TimeInterval = 0.4
    }
}

/// What motion is allowed right now. Every helper funnels through this, so the
/// Reduce Motion fallback lives in one place (and is unit-tested).
struct MotionPolicy: Equatable, Sendable {
    let reduceMotion: Bool

    /// The system setting, for code that is not inside a view.
    @MainActor
    static var current: MotionPolicy {
        MotionPolicy(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// `animation`, or nil (an instant change) under Reduce Motion.
    func animation(_ animation: Animation?) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// `transition`, or `.identity` (appear and disappear in place) under
    /// Reduce Motion.
    func transition(_ transition: AnyTransition) -> AnyTransition {
        reduceMotion ? .identity : transition
    }

    /// `seconds`, or 0 under Reduce Motion.
    func duration(_ seconds: TimeInterval) -> TimeInterval {
        reduceMotion ? 0 : seconds
    }

    /// Whether views may fly between positions with `matchedGeometryEffect`.
    var allowsMatchedGeometry: Bool { !reduceMotion }
}

/// `withAnimation`, honouring Reduce Motion: the change still happens, just
/// without animating.
@MainActor
@discardableResult
func withMotion<Result>(
    _ animation: Animation? = Motion.snappy,
    policy: MotionPolicy = .current,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(policy.animation(animation), body)
}

extension View {
    /// `.animation(_:value:)`, honouring Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation? = Motion.snappy, value: Value) -> some View {
        modifier(MotionAnimationModifier(animation: animation, value: value))
    }

    /// `.transition(_:)`, honouring Reduce Motion (an instant appear/disappear).
    func motionTransition(_ transition: AnyTransition) -> some View {
        modifier(MotionTransitionModifier(transition: transition))
    }

    /// `.matchedGeometryEffect(id:in:)`, skipped under Reduce Motion so the
    /// view appears in place instead of flying from its old position.
    func motionMatchedGeometry<ID: Hashable>(
        id: ID,
        in namespace: Namespace.ID,
        properties: MatchedGeometryProperties = .frame,
        anchor: UnitPoint = .center,
        isSource: Bool = true
    ) -> some View {
        modifier(MotionMatchedGeometryModifier(
            id: id, namespace: namespace, properties: properties, anchor: anchor, isSource: isSource
        ))
    }
}

private struct MotionAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: Value

    func body(content: Content) -> some View {
        content.animation(MotionPolicy(reduceMotion: reduceMotion).animation(animation), value: value)
    }
}

private struct MotionTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let transition: AnyTransition

    func body(content: Content) -> some View {
        content.transition(MotionPolicy(reduceMotion: reduceMotion).transition(transition))
    }
}

private struct MotionMatchedGeometryModifier<ID: Hashable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: ID
    let namespace: Namespace.ID
    let properties: MatchedGeometryProperties
    let anchor: UnitPoint
    let isSource: Bool

    func body(content: Content) -> some View {
        if MotionPolicy(reduceMotion: reduceMotion).allowsMatchedGeometry {
            content.matchedGeometryEffect(
                id: id, in: namespace, properties: properties, anchor: anchor, isSource: isSource
            )
        } else {
            content
        }
    }
}

// MARK: - Loops and progress

extension Motion {
    /// A progress bar or ring catching up with a new reading. Readings arrive
    /// a few times a second, so this runs slightly longer than the gap between
    /// them and the fill glides instead of stepping. No overshoot: a progress
    /// bar must never appear to run backwards.
    static let progressFill = Animation.smooth(duration: 0.35)

    /// A seamless, endless crawl (a drop target's "marching ants" border).
    /// Only for something the user is actively doing, such as hovering a
    /// drag, so it never runs while the window sits idle.
    static let marchingAnts = Animation.linear(duration: 0.8).repeatForever(autoreverses: false)

    /// How long decorative idle loops (a plug inviting the user to plug in,
    /// the connection steps taking turns) keep playing once their window is
    /// live, before the picture settles. Pointer movement over the view, the
    /// window becoming active again, or a new screen re-arms them.
    static let idleLoopBudget: Swift.Duration = .seconds(12)
}

extension EnvironmentValues {
    /// Whether looping progress animations (a sheen on a filling bar, a
    /// spinner, a handshake signal) may run: the window is on screen and
    /// active, the app is frontmost, and Reduce Motion is off. Published by
    /// `motionLiveness(rearmingOn:)`; false (a still picture)
    /// anywhere it is not installed.
    @Entry var motionIsLive = false

    /// Whether purely decorative idle loops may run: ``motionIsLive`` and
    /// the view has seen activity within ``Motion/idleLoopBudget``. An idle
    /// window therefore costs nothing once it has settled.
    @Entry var motionAllowsIdleLoops = false
}

extension View {
    /// Publishes ``EnvironmentValues/motionIsLive`` and
    /// ``EnvironmentValues/motionAllowsIdleLoops`` to this subtree. Install it
    /// once per window, at the root. `rearmingOn` restarts the idle-loop
    /// budget when it changes (a new screen).
    func motionLiveness(rearmingOn trigger: some Hashable = 0) -> some View {
        modifier(MotionLivenessModifier(trigger: AnyHashable(trigger)))
    }
}

private struct MotionLivenessModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    let trigger: AnyHashable
    @State private var isWindowVisible = true
    /// Bumped by activity; the idle-loop budget restarts each time.
    @State private var activity = 0
    @State private var idleLoopsExpired = false

    func body(content: Content) -> some View {
        let isLive = isWindowVisible && controlActiveState != .inactive && !reduceMotion
        content
            .environment(\.motionIsLive, isLive)
            .environment(\.motionAllowsIdleLoops, isLive && !idleLoopsExpired)
            .background(WindowOcclusionObserver(isVisible: $isWindowVisible))
            .onContinuousHover { phase in
                // Only a settled view needs waking; a live one ignores the
                // pointer, so hovering costs no state updates.
                if case .active = phase, idleLoopsExpired { activity += 1 }
            }
            .task(id: IdleBudgetKey(isLive: isLive, trigger: trigger, activity: activity)) {
                idleLoopsExpired = false
                guard isLive else { return }
                guard (try? await Task.sleep(for: Motion.idleLoopBudget)) != nil else { return }
                idleLoopsExpired = true
            }
    }

    private struct IdleBudgetKey: Hashable {
        let isLive: Bool
        let trigger: AnyHashable
        let activity: Int
    }
}

/// Reports whether the hosting window is at least partly on screen, so loops
/// stop while it is minimised, hidden or covered.
private struct WindowOcclusionObserver: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.report = { visible in isVisible = visible }
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.report = { visible in isVisible = visible }
    }

    final class ObserverView: NSView {
        var report: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            publish()
        }

        private func publish() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
            // Deferred: this can run during a SwiftUI update.
            DispatchQueue.main.async { [report] in report?(visible) }
        }
    }
}

// MARK: - One-shot feedback

extension View {
    /// `.symbolEffect(.bounce, value:)`, skipped under Reduce Motion: SF
    /// Symbols bounce whenever `value` changes, whatever the transaction.
    func motionBounce<Value: Equatable>(value: Value) -> some View {
        modifier(MotionBounceModifier(value: value))
    }

    /// Spins the SF Symbols inside this view a turn each time `value` changes
    /// (Refresh); a bounce where the spin effect is unavailable. Nothing under
    /// Reduce Motion.
    func motionSpin<Value: Equatable>(value: Value) -> some View {
        modifier(MotionSpinModifier(value: value))
    }

    /// A short horizontal shake each time `trigger` changes: the macOS "that
    /// didn't work" gesture. Nothing under Reduce Motion.
    func motionShake<Trigger: Equatable & Sendable>(trigger: Trigger) -> some View {
        modifier(MotionShakeModifier(trigger: trigger))
    }

    /// A short, springy pop, played whenever `trigger` changes to a new
    /// non-nil value (an item the user just created or renamed). Pass nil for
    /// views that should stay still; the animator stays installed either way,
    /// so the first pop plays too. Nothing under Reduce Motion.
    func motionPop(trigger: Int?) -> some View {
        modifier(MotionPopModifier(trigger: trigger))
    }
}

private struct MotionBounceModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.bounce, value: value)
        }
    }
}

private struct MotionSpinModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else if #available(macOS 15.0, *) {
            content.symbolEffect(.rotate.byLayer, options: .speed(1.6), value: value)
        } else {
            content.symbolEffect(.bounce, value: value)
        }
    }
}

private struct MotionShakeModifier<Trigger: Equatable & Sendable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trigger: Trigger

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { view, offset in
                view.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-7, duration: 0.06)
                    CubicKeyframe(6, duration: 0.07)
                    CubicKeyframe(-4, duration: 0.07)
                    CubicKeyframe(2, duration: 0.07)
                    SpringKeyframe(0, duration: 0.12)
                }
            }
        }
    }
}

private struct MotionPopModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trigger: Int?

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                // Going back to nil (the highlight moved on) stays at rest.
                KeyframeTrack {
                    CubicKeyframe(trigger == nil ? 1 : 1.16, duration: 0.12)
                    SpringKeyframe(1, duration: Motion.Duration.slow, spring: .bouncy)
                }
            }
        }
    }
}

// MARK: - Staggered appearance

extension Motion {
    /// The delay between neighbours in a staggered appearance, in seconds.
    static let staggerStep: TimeInterval = 0.05
}

extension View {
    /// Fades and lifts the view into place when it first appears, `index`
    /// steps after its first sibling, so a list or a page's blocks arrive in
    /// sequence rather than all at once. Under Reduce Motion it is simply
    /// there.
    func staggeredAppearance(index: Int, animation: Animation = Motion.gentle) -> some View {
        modifier(StaggeredAppearanceModifier(index: index, animation: animation))
    }
}

private struct StaggeredAppearanceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let animation: Animation
    @State private var isVisible = false

    func body(content: Content) -> some View {
        let isShown = isVisible || reduceMotion
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : 8)
            .onAppear {
                guard !isVisible else { return }
                let delay = Motion.staggerStep * Double(max(index, 0))
                withAnimation(MotionPolicy(reduceMotion: reduceMotion).animation(animation.delay(delay))) {
                    isVisible = true
                }
            }
    }
}
