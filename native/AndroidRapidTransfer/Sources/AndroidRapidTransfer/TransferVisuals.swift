import AndroidRapidTransferCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The transfer panel's small animated pieces: progress bar and ring, a
// self-drawing checkmark, a one-shot celebration burst and a failure shake.
// Everything animates through `Motion`, so Reduce Motion turns each into an
// instant change, and nothing runs a timeline unless bytes are moving.

private enum TransferSheenTiming {
    /// Seconds for one pass of the sheen across a filling bar.
    static let period: TimeInterval = 1.8
}

// MARK: - Progress bar

/// A capsule progress bar. `value` is 0...1, or `nil` while the total is
/// unknown. While `isFlowing` a soft highlight sweeps across the filled part;
/// it stops (and its timeline is torn down) as soon as bytes stop moving.
struct TransferProgressBar: View {
    let value: Double?
    var isFlowing = false
    var tint: Color = .accentColor
    var height: CGFloat = 6

    /// Off while the window is hidden, inactive or in the background, and
    /// under Reduce Motion: the sheen and the indeterminate glide stop.
    @Environment(\.motionIsLive) private var isLive

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if let value {
                    let fraction = min(max(value, 0), 1)
                    Capsule()
                        .fill(tint.gradient)
                        .overlay {
                            if isFlowing, isLive {
                                TransferSheen()
                            }
                        }
                        .clipShape(Capsule())
                        .frame(width: fraction > 0 ? max(height, width * fraction) : 0)
                        .motion(Motion.progressFill, value: fraction)
                } else {
                    TransferIndeterminateFill(tint: tint, isAnimating: isLive)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int((min(max($0, 0), 1) * 100).rounded())) percent" } ?? "Preparing")
    }
}

/// A highlight that sweeps left to right across its container, forever while
/// it is on screen. Only ever shown while a transfer is moving bytes.
private struct TransferSheen: View {
    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let width = proxy.size.width
                let band = max(36, width * 0.35)
                let seconds = context.date.timeIntervalSinceReferenceDate
                let phase = seconds.truncatingRemainder(dividingBy: TransferSheenTiming.period) / TransferSheenTiming.period
                LinearGradient(
                    colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + phase * (width + band))
                .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The "working on it" fill for a bar whose total is not known yet: a short
/// segment gliding back and forth, or a faint full track under Reduce Motion.
private struct TransferIndeterminateFill: View {
    let tint: Color
    let isAnimating: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            if isAnimating {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let seconds = context.date.timeIntervalSinceReferenceDate
                    // 0...1...0 over 1.6 s, eased at the ends.
                    let raw = seconds.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let phase = (1 - cos(raw * 2 * .pi)) / 2
                    let segment = width * 0.3
                    Capsule()
                        .fill(tint.opacity(0.8))
                        .frame(width: segment)
                        .offset(x: phase * (width - segment))
                }
            } else {
                Capsule()
                    .fill(tint.opacity(0.35))
            }
        }
    }
}

// MARK: - Progress ring

/// A circular gauge for the panel header, with an SF Symbol in the middle.
/// An unknown total shows a slowly turning arc instead of a fill.
struct TransferProgressRing: View {
    let value: Double?
    let systemImage: String
    var tint: Color = .accentColor
    var diameter: CGFloat = 30
    var lineWidth: CGFloat = 3.5

    @Environment(\.motionIsLive) private var isLive

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            if let value {
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .motion(Motion.progressFill, value: value)
            } else if !isLive {
                arc(rotation: .zero)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let seconds = context.date.timeIntervalSinceReferenceDate
                    arc(rotation: .degrees(seconds.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                }
            }
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func arc(rotation: Angle) -> some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(rotation - .degrees(90))
    }
}

// MARK: - Checkmark

/// A green disc whose check draws itself: the disc pops in, then the stroke
/// traces from left to right. With `animated` false (or Reduce Motion) it
/// simply appears, which is how rows that finished a while ago show up when
/// scrolled into view.
struct TransferCheckmark: View {
    var diameter: CGFloat = 16
    var tint: Color = .green
    @State private var discScale: CGFloat
    @State private var stroke: CGFloat

    init(diameter: CGFloat = 16, tint: Color = .green, animated: Bool) {
        self.diameter = diameter
        self.tint = tint
        _discScale = State(initialValue: animated ? 0.3 : 1)
        _stroke = State(initialValue: animated ? 0 : 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.gradient)
                .scaleEffect(discScale)
            TransferCheckShape()
                .trim(from: 0, to: stroke)
                .stroke(.white, style: StrokeStyle(lineWidth: diameter * 0.13, lineCap: .round, lineJoin: .round))
                .padding(diameter * 0.26)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
        .onAppear {
            guard stroke < 1 else { return }
            withMotion(Motion.bouncy) { discScale = 1 }
            withMotion(Motion.gentle.delay(0.1)) { stroke = 1 }
        }
    }
}

private struct TransferCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return path
    }
}

// MARK: - Celebration

/// A small burst of confetti and sparkles around its container, played once
/// each time `trigger` changes to a new non-nil value. Nothing is drawn at
/// rest, and nothing at all under Reduce Motion.
struct TransferCelebrationBurst: View {
    let trigger: UUID?
    var radius: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let particleCount = 14
    private static let palette: [Color] = [.green, .yellow, .pink, .accentColor, .orange, .mint, .purple]

    var body: some View {
        if !reduceMotion {
            ZStack {
                ForEach(0 ..< Self.particleCount, id: \.self) { index in
                    particle(index)
                }
            }
            .keyframeAnimator(initialValue: BurstFrame(), trigger: trigger) { content, frame in
                content
                    .environment(\.transferBurstProgress, frame.progress)
                    .opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.progress) {
                    MoveKeyframe(0)
                    SpringKeyframe(1, duration: 0.7, spring: .init(response: 0.45, dampingRatio: 0.7))
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(1)
                    LinearKeyframe(1, duration: 0.35)
                    LinearKeyframe(0, duration: 0.45)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func particle(_ index: Int) -> some View {
        let angle = Double(index) / Double(Self.particleCount) * 2 * .pi + (index.isMultiple(of: 2) ? 0.2 : -0.1)
        let distance = radius * (0.75 + 0.25 * Double(index % 3))
        let color = Self.palette[index % Self.palette.count]
        return TransferBurstParticle(
            angle: angle,
            distance: distance,
            color: color,
            isSparkle: index % 3 == 0
        )
    }

    private struct BurstFrame {
        var progress: CGFloat = 0
        var opacity: Double = 0
    }
}

private struct TransferBurstParticle: View {
    let angle: Double
    let distance: CGFloat
    let color: Color
    let isSparkle: Bool
    @Environment(\.transferBurstProgress) private var progress

    var body: some View {
        Group {
            if isSparkle {
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(color)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3.5, height: 6)
                    .rotationEffect(.radians(angle + progress * 3))
            }
        }
        .scaleEffect(1.2 - 0.6 * progress)
        .offset(x: cos(angle) * distance * progress, y: sin(angle) * distance * progress)
    }
}

private struct TransferBurstProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var transferBurstProgress: CGFloat {
        get { self[TransferBurstProgressKey.self] }
        set { self[TransferBurstProgressKey.self] = newValue }
    }
}

// MARK: - Item icons

/// Finder's icon for the kind of item a transfer row or queue row carries.
@MainActor
enum TransferItemIcon {
    private static var cache: [String: NSImage] = [:]

    /// The icon for a transfer job: a generic item for several sources, a
    /// folder for a directory source, otherwise the file's type. Uploads have
    /// no directory hint in the request, so a lone upload source's name
    /// without an extension is treated as a folder (the usual case).
    static func image(for request: TransferRequest, name: String) -> NSImage {
        if request.sources.count > 1 {
            return image(name: name, isDirectory: false, isGroup: true)
        }
        let isDirectory = !request.directorySources.isDisjoint(with: request.sources)
            || request.direction == .upload && (name as NSString).pathExtension.isEmpty
        return image(name: name, isDirectory: isDirectory)
    }

    static func image(name: String, isDirectory: Bool, isGroup: Bool = false) -> NSImage {
        let type: UTType
        if isGroup {
            type = .item
        } else if isDirectory {
            type = .folder
        } else {
            let pathExtension = (name as NSString).pathExtension
            type = pathExtension.isEmpty ? .data : UTType(filenameExtension: pathExtension) ?? .data
        }
        if let cached = cache[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = image
        return image
    }
}
