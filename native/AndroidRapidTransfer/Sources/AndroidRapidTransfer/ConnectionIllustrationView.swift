import SwiftUI

/// The phone, cable and Mac at the top of every connection screen. It stays
/// on screen while the pane moves between those screens, so a change of state
/// reads as the same picture changing: the plug seats when a phone is found,
/// a ring counts reconnect attempts, the plug demonstrates a replug.
///
/// Purely decorative (the text beside it carries the meaning), so it is hidden
/// from accessibility. Its loops (the plug's invitation, the handshake signal,
/// the breathing attempt) run only while
/// ``EnvironmentValues/motionAllowsIdleLoops``; otherwise it is a still picture
/// and the screen's text shows a system spinner where progress matters.
struct ConnectionIllustrationView: View {
    enum Mode: Equatable {
        /// Unplugged; the plug edges towards the phone now and then.
        case waiting
        /// Plugged in; a signal travels back and forth while the app talks to the phone.
        case handshake
        /// A ring around the phone fills one segment per reconnect attempt.
        case reconnecting(attempt: Int, limit: Int, isAttempting: Bool)
        /// Unplugged; the plug shows the unplug-and-reconnect gesture.
        case replug
        /// Plugged in, with a failure mark on the cable.
        case failed
    }

    let mode: Mode
    /// Changes when a failure happens again, to shake the picture.
    var failureCount = 0

    @Environment(\.motionAllowsIdleLoops) private var allowsIdleLoops

    private static let cableLength: CGFloat = 112
    private static let unpluggedGap: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            phone
            cable
            Image(systemName: "laptopcomputer")
                .font(.system(size: 54, weight: .ultraLight))
                .foregroundStyle(macColor)
                .frame(width: 66, height: 76)
        }
        .motionShake(trigger: failureCount)
        .motion(Motion.bouncy, value: mode)
        .accessibilityHidden(true)
    }

    // MARK: - Phone

    private var phone: some View {
        ZStack {
            if case let .reconnecting(attempt, limit, isAttempting) = mode {
                ConnectionAttemptRing(attempt: attempt, limit: limit, isAttempting: isAttempting)
                    .frame(width: 58, height: 58)
                    .motionTransition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Image(systemName: "smartphone")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(phoneColor)
                .scaleEffect(isReconnecting ? 0.72 : 1)
        }
        // Narrower than the glyph's column would be, so a seated plug meets
        // the phone; the attempt ring overhangs onto the cable.
        .frame(width: 26, height: 76)
    }

    // MARK: - Cable

    private var cable: some View {
        CableView(
            color: cableColor,
            isDashed: isCableDashed,
            gap: plugGap,
            loop: plugLoop
        )
        .frame(width: Self.cableLength, height: 24)
        .clipped()
        .overlay {
            if mode == .handshake, allowsIdleLoops {
                SignalDot(travel: Self.cableLength - 12)
                    .transition(.opacity)
            }
        }
        .overlay {
            if mode == .failed {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .background(Circle().fill(.background).padding(-2))
                    .motionBounce(value: failureCount)
                    .motionTransition(.scale.combined(with: .opacity))
            }
        }
    }

    private var plugLoop: CableView.Loop? {
        guard allowsIdleLoops else { return nil }
        return switch mode {
        case .waiting: .approach
        case .replug: .replug
        default: nil
        }
    }

    private var plugGap: CGFloat {
        switch mode {
        case .waiting, .replug: Self.unpluggedGap
        // Clear of the attempt ring around the phone.
        case let .reconnecting(_, _, isAttempting): isAttempting ? 22 : Self.unpluggedGap + 14
        case .handshake, .failed: 0
        }
    }

    private var isCableDashed: Bool {
        switch mode {
        case .waiting, .replug: true
        case let .reconnecting(_, _, isAttempting): !isAttempting
        case .handshake, .failed: false
        }
    }

    private var isReconnecting: Bool {
        if case .reconnecting = mode { true } else { false }
    }

    // MARK: - Colours

    private var cableColor: Color {
        switch mode {
        case .waiting: .secondary.opacity(0.7)
        case .handshake: .accentColor
        case .reconnecting: .accentColor.opacity(0.75)
        case .replug: .orange
        case .failed: .secondary
        }
    }

    private var phoneColor: Color {
        switch mode {
        case .waiting, .failed: .secondary
        case .handshake, .reconnecting: .primary
        case .replug: .orange
        }
    }

    private var macColor: Color {
        mode == .handshake ? .primary : .secondary
    }
}

/// The cable from the Mac, ending in a plug `gap` points short of the phone.
private struct CableView: View {
    enum Loop {
        /// Now and then the plug edges most of the way in: "plug me in".
        case approach
        /// The plug seats, pauses, and comes out again: "unplug and reconnect".
        case replug
    }

    let color: Color
    let isDashed: Bool
    let gap: CGFloat
    let loop: Loop?

    var body: some View {
        // Fills the cable's width; pushed right by `gap` (and the loops), with
        // the end past the Mac clipped away by the caller.
        cable.offset(x: gap)
    }

    @ViewBuilder
    private var cable: some View {
        switch loop {
        case .approach:
            plugAndLine.keyframeAnimator(initialValue: CGFloat.zero) { view, nudge in
                view.offset(x: nudge)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 1.6)
                    SpringKeyframe(-11, duration: 0.45, spring: .smooth)
                    LinearKeyframe(-11, duration: 0.25)
                    SpringKeyframe(0, duration: 0.5, spring: .smooth)
                }
            }
        case .replug:
            plugAndLine.keyframeAnimator(initialValue: CGFloat.zero) { view, nudge in
                view.offset(x: nudge)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 0.9)
                    SpringKeyframe(-18, duration: 0.4, spring: .snappy)
                    LinearKeyframe(-18, duration: 0.9)
                    SpringKeyframe(0, duration: 0.4, spring: .snappy)
                }
            }
        case nil:
            plugAndLine
        }
    }

    private var plugAndLine: some View {
        HStack(spacing: 0) {
            // The plug: a metal tip and a moulded head.
            RoundedRectangle(cornerRadius: 1)
                .fill(color.opacity(0.55))
                .frame(width: 5, height: 5)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color)
                .frame(width: 12, height: 10)
            Line()
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: isDashed ? [4, 5] : [])
                )
                .frame(height: 2.5)
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// A glowing dot travelling along the cable and back: the handshake.
private struct SignalDot: View {
    let travel: CGFloat

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .shadow(color: .accentColor.opacity(0.9), radius: 4)
            .keyframeAnimator(initialValue: SignalPosition()) { view, position in
                view
                    .offset(x: position.x)
                    .opacity(position.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    CubicKeyframe(travel, duration: 0.8)
                    LinearKeyframe(travel, duration: 0.15)
                    CubicKeyframe(0, duration: 0.8)
                    LinearKeyframe(0, duration: 0.15)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.2)
                    LinearKeyframe(1, duration: 0.5)
                    LinearKeyframe(0.2, duration: 0.25)
                    LinearKeyframe(1, duration: 0.2)
                    LinearKeyframe(1, duration: 0.5)
                    LinearKeyframe(0.2, duration: 0.25)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
    }

    private struct SignalPosition {
        var x: CGFloat = 0
        var opacity: Double = 0.2
    }
}

/// A ring of `limit` segments around the phone, one filled per reconnect
/// attempt; the running attempt breathes while the window is live and has
/// not sat idle for long.
struct ConnectionAttemptRing: View {
    let attempt: Int
    let limit: Int
    let isAttempting: Bool

    @Environment(\.motionAllowsIdleLoops) private var isLive

    var body: some View {
        ZStack {
            ForEach(0..<max(limit, 1), id: \.self) { index in
                segment(index)
            }
        }
        .rotationEffect(.degrees(-90))
        .motion(Motion.bouncy, value: attempt)
    }

    @ViewBuilder
    private func segment(_ index: Int) -> some View {
        let count = Double(max(limit, 1))
        let spacing = 0.035
        let arc = Circle()
            .trim(from: Double(index) / count + spacing, to: Double(index + 1) / count - spacing)
            .stroke(
                index < attempt ? Color.accentColor : Color.secondary.opacity(0.25),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
            )
        if index == attempt - 1, isAttempting, isLive {
            arc.phaseAnimator([1.0, 0.35]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
        } else {
            arc
        }
    }
}
