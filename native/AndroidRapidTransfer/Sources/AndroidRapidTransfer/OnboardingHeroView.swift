import SwiftUI

/// The illustration at the top of the onboarding sheet: a phone and a Mac on
/// the app icon's gradient, telling the setup story as the pages advance. The
/// welcome page sends photos across; the setup steps unlock the phone, plug
/// in the cable and pick File transfer; the finish page sends a last burst
/// and celebrates. State accumulates, so going forward builds the scene up
/// and every step is visible at a glance.
///
/// Every animation is triggered by a page change or a click and ends on its
/// own; nothing loops while the sheet sits idle. Under Reduce Motion each page
/// shows its end state directly.
struct OnboardingHeroView: View {
    let page: OnboardingPage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var selection

    @State private var isUnlocked = true
    @State private var cableProgress: CGFloat = 0
    @State private var isPlugged = false
    @State private var picksFileTransfer = false
    @State private var dataPulses = 0
    @State private var flights: [OnboardingFlight] = []
    @State private var nextFlightID = 0
    @State private var received = 0
    @State private var celebrations = 0

    static let size = CGSize(width: 560, height: 212)
    private static let phoneCenter = CGPoint(x: 176, y: 102)
    private static let macCenter = CGPoint(x: 384, y: 90)
    private static let phoneSize = CGSize(width: 88, height: 150)
    private static let displaySize = CGSize(width: 180, height: 114)
    /// Where a sent file leaves the phone, peaks, and lands on the Mac.
    static let flightPath = OnboardingArc(
        from: CGPoint(x: phoneCenter.x, y: phoneCenter.y - 6),
        control: CGPoint(x: (phoneCenter.x + macCenter.x) / 2, y: -24),
        to: macCenter
    )

    var body: some View {
        ZStack(alignment: .topLeading) {
            stage
            cable
            mac
                .position(Self.macCenter)
            phone
                .position(Self.phoneCenter)
            ForEach(flights) { flight in
                OnboardingFlightView(flight: flight, path: Self.flightPath)
            }
            OnboardingSparkleBurst(trigger: celebrations)
                .position(Self.macCenter)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: sendFile)
        .task(id: page) { await play(page) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isImage)
    }

    // MARK: - Scene

    private var stage: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(OnboardingPalette.stageGradient)
            .overlay {
                // Soft light from the top, as on the app icon.
                RadialGradient(
                    colors: [.white.opacity(0.28), .clear],
                    center: UnitPoint(x: 0.3, y: -0.2),
                    startRadius: 0,
                    endRadius: 420
                )
            }
            .overlay {
                if colorScheme == .dark {
                    Color.black.opacity(0.18)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
    }

    private var phone: some View {
        OnboardingDeviceShell(size: Self.phoneSize, cornerRadius: 18, bezel: 5, screenCornerRadius: 13) {
            phoneScreen
        }
        .overlay(alignment: .bottom) {
            // The plug seated in the phone's port.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(.white)
                .frame(width: 14, height: 7)
                .offset(y: 6)
                .opacity(isPlugged ? 1 : 0)
        }
        .shadow(color: .white.opacity(isSpotlit(.phone) ? 0.55 : 0), radius: 14)
        .scaleEffect(isSpotlit(.phone) ? 1.07 : 1, anchor: .bottom)
        .motion(Motion.bouncy, value: page)
    }

    @ViewBuilder
    private var phoneScreen: some View {
        switch page {
        case .welcome, .done:
            OnboardingPhotoGrid(columns: 2, rows: 3, tile: 20, spacing: 6)
                .overlay {
                    if page == .done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, OnboardingPalette.success)
                            .shadow(radius: 4)
                            .motionBounce(value: celebrations)
                            .motionTransition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
        case .unlock:
            VStack(spacing: 8) {
                Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                Capsule()
                    .fill(.white.opacity(0.6))
                    .frame(width: 26, height: 4)
                    .offset(y: isUnlocked ? -10 : 0)
                    .opacity(isUnlocked ? 0 : 1)
            }
        case .plugIn:
            Image(systemName: isPlugged ? "bolt.fill" : "bolt.slash")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(isPlugged ? OnboardingPalette.warm : .white.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
                .motionBounce(value: isPlugged)
        case .fileTransfer:
            usbOptions
        }
    }

    /// The phone's "use USB for" choice, with the selection sliding from
    /// charging to File transfer.
    private var usbOptions: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("USB")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
            usbOption("File transfer", isSelected: picksFileTransfer)
            usbOption("Charging only", isSelected: !picksFileTransfer)
            usbOption("MIDI", isSelected: false)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usbOption(_ title: String, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.7), lineWidth: 1.2)
                    .frame(width: 10, height: 10)
                if isSelected {
                    Circle()
                        .fill(OnboardingPalette.warm)
                        .frame(width: 6, height: 6)
                        .motionMatchedGeometry(id: "usb-selection", in: selection)
                }
            }
            Text(title)
                .font(.system(size: 8, weight: isSelected ? .bold : .regular))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.75))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var mac: some View {
        VStack(spacing: 0) {
            OnboardingDeviceShell(size: Self.displaySize, cornerRadius: 12, bezel: 7, screenCornerRadius: 6) {
                macScreen
            }
            // Stand: a tapered neck and a foot.
            OnboardingStandNeck()
                .fill(Color(white: 0.86))
                .frame(width: 44, height: 22)
            Capsule()
                .fill(Color(white: 0.92))
                .frame(width: 92, height: 7)
        }
        .overlay(alignment: .topTrailing) {
            if received > 0, page == .welcome || page == .done {
                receivedBadge
                    .offset(x: 10, y: -10)
                    .motionTransition(.scale.combined(with: .opacity))
            }
        }
        .shadow(color: .white.opacity(isSpotlit(.mac) ? 0.55 : 0), radius: 14)
        .motion(Motion.bouncy, value: page)
    }

    private var macScreen: some View {
        ZStack {
            OnboardingReceivedGrid(count: received)
            if page == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, OnboardingPalette.success)
                    .shadow(radius: 6)
                    .motionBounce(value: celebrations)
                    .motionTransition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
    }

    private var receivedBadge: some View {
        Label {
            Text(received, format: .number)
                .contentTransition(.numericText(value: Double(received)))
        } icon: {
            Image(systemName: "photo.fill")
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(OnboardingPalette.warm.gradient))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .motion(Motion.snappy, value: received)
    }

    private var cable: some View {
        ZStack {
            OnboardingCablePath()
                .trim(from: 0, to: cableProgress)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            OnboardingCablePulse(trigger: dataPulses)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
    }

    // MARK: - Story

    private enum Device { case phone, mac }

    private func isSpotlit(_ device: Device) -> Bool {
        switch page {
        case .unlock, .fileTransfer: device == .phone
        case .welcome, .plugIn, .done: false
        }
    }

    /// Sets the scene for `page`, then plays its moment.
    private func play(_ page: OnboardingPage) async {
        let policy = MotionPolicy(reduceMotion: reduceMotion)
        let reachedStep = { (step: OnboardingPage) in page.rawValue >= step.rawValue }
        // Pages before this one are already done; later ones not yet. Jumping
        // across several pages eases the scene into place.
        withMotion(Motion.gentle, policy: policy) {
            isUnlocked = page != .unlock
            if !reachedStep(.plugIn) {
                cableProgress = 0
                isPlugged = false
            } else if page != .plugIn {
                cableProgress = 1
                isPlugged = true
            }
            picksFileTransfer = page.rawValue > OnboardingPage.fileTransfer.rawValue
        }

        switch page {
        case .welcome:
            for delay in [0.5, 1.3, 1.1, 1.1] {
                guard await pause(delay, policy) else { return }
                sendFile()
            }
        case .unlock:
            guard await pause(0.6, policy) else { return }
            withMotion(Motion.bouncy, policy: policy) { isUnlocked = true }
        case .plugIn:
            withAnimation(nil) {
                cableProgress = 0
                isPlugged = false
            }
            guard await pause(0.3, policy) else { return }
            withMotion(Motion.gentle, policy: policy) { cableProgress = 1 }
            guard await pause(Motion.Duration.slow, policy) else { return }
            withMotion(Motion.bouncy, policy: policy) { isPlugged = true }
        case .fileTransfer:
            guard await pause(0.6, policy) else { return }
            withMotion(Motion.snappy, policy: policy) { picksFileTransfer = true }
            guard !policy.reduceMotion else { return }
            for _ in 0..<2 {
                guard await pause(0.45, policy) else { return }
                dataPulses += 1
            }
        case .done:
            for _ in 0..<3 {
                guard await pause(0.35, policy) else { return }
                sendFile()
            }
            guard await pause(0.5, policy), !policy.reduceMotion else { return }
            celebrations += 1
        }
    }

    /// Sleeps for `seconds` (nothing under Reduce Motion); false once the
    /// page has changed or the sheet has closed.
    private func pause(_ seconds: TimeInterval, _ policy: MotionPolicy) async -> Bool {
        let duration = policy.duration(seconds)
        if duration > 0 {
            try? await Task.sleep(for: .seconds(duration))
        }
        return !Task.isCancelled
    }

    /// Flies a photo from the phone to the Mac. Clicking the scene sends one
    /// too, for anyone who wants to watch it again.
    private func sendFile() {
        guard page == .welcome || page == .done else { return }
        let policy = MotionPolicy(reduceMotion: reduceMotion)
        guard !policy.reduceMotion else {
            received += 1
            return
        }
        let flight = OnboardingFlight(id: nextFlightID, tint: OnboardingPalette.tile(nextFlightID))
        nextFlightID += 1
        flights.append(flight)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(OnboardingFlightView.duration))
            flights.removeAll { $0.id == flight.id }
            withMotion(Motion.bouncy, policy: policy) { received += 1 }
        }
    }

    private var accessibilityDescription: String {
        switch page {
        case .welcome: String(localized: "Photos flying from a phone to a Mac.")
        case .unlock: String(localized: "A phone being unlocked.")
        case .plugIn: String(localized: "A USB cable connecting the phone to the Mac.")
        case .fileTransfer: String(localized: "The phone's USB options, with File transfer selected.")
        case .done: String(localized: "The phone and the Mac, connected and ready.")
        }
    }
}

// MARK: - Pieces

enum OnboardingPalette {
    /// The app icon's gradient: the phone's green into the Mac's blue.
    static let stageGradient = LinearGradient(
        colors: [
            Color(red: 0.18, green: 0.84, blue: 0.52),
            Color(red: 0.05, green: 0.70, blue: 0.66),
            Color(red: 0.13, green: 0.46, blue: 0.96),
            Color(red: 0.29, green: 0.30, blue: 0.93)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let screen = LinearGradient(
        colors: [Color(red: 0.09, green: 0.19, blue: 0.36), Color(red: 0.14, green: 0.27, blue: 0.58)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let warm = Color(red: 1, green: 0.64, blue: 0.2)
    static let success = Color(red: 0.2, green: 0.78, blue: 0.45)

    private static let tiles = [
        Color(red: 0.35, green: 0.86, blue: 0.62),
        Color(red: 0.99, green: 0.78, blue: 0.30),
        Color(red: 0.47, green: 0.66, blue: 1.00),
        Color(red: 0.99, green: 0.53, blue: 0.42),
        Color(red: 0.60, green: 0.55, blue: 1.00),
        Color(red: 0.35, green: 0.86, blue: 0.86)
    ]

    static func tile(_ index: Int) -> Color {
        tiles[((index % tiles.count) + tiles.count) % tiles.count]
    }
}

/// A white device body with a dark inset screen.
private struct OnboardingDeviceShell<Screen: View>: View {
    let size: CGSize
    let cornerRadius: CGFloat
    let bezel: CGFloat
    let screenCornerRadius: CGFloat
    @ViewBuilder let screen: Screen

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(white: 0.97))
            .overlay {
                RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous)
                    .fill(OnboardingPalette.screen)
                    .overlay { screen }
                    .clipShape(RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous))
                    .padding(bezel)
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: Color(red: 0.02, green: 0.08, blue: 0.25).opacity(0.35), radius: 10, y: 5)
    }
}

private struct OnboardingStandNeck: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The phone's gallery: a small grid of photo tiles.
private struct OnboardingPhotoGrid: View {
    let columns: Int
    let rows: Int
    let tile: CGFloat
    let spacing: CGFloat

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(OnboardingPalette.tile(row * columns + column))
                            .frame(width: tile, height: tile)
                    }
                }
            }
        }
    }
}

/// The photos that have arrived on the Mac, popping in one by one.
private struct OnboardingReceivedGrid: View {
    let count: Int
    private static let columns = 5
    private static let capacity = 10

    var body: some View {
        // Past a full screen, the oldest photos scroll off.
        let first = max(0, count - Self.capacity)
        let indices = Array(first..<count)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(indices.dropFirst(row * Self.columns).prefix(Self.columns), id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(OnboardingPalette.tile(index))
                            .frame(width: 24, height: 24)
                            .motionTransition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .frame(width: 144, height: 24, alignment: .leading)
            }
        }
    }
}

/// The cable from the phone's port, sagging under both devices, into the Mac.
private struct OnboardingCablePath: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 176, y: 182))
            path.addCurve(
                to: CGPoint(x: 336, y: 172),
                control1: CGPoint(x: 176, y: 214),
                control2: CGPoint(x: 330, y: 214)
            )
        }
    }
}

/// A bright blip running along the cable: data on the move.
private struct OnboardingCablePulse: View {
    let trigger: Int

    private static let length: CGFloat = 0.16

    var body: some View {
        KeyframeAnimator(initialValue: PulseFrame(), trigger: trigger) { frame in
            OnboardingCablePath()
                .trim(from: frame.offset, to: frame.offset + Self.length)
                .stroke(OnboardingPalette.warm, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .opacity(frame.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.offset) {
                LinearKeyframe(0, duration: 0.01)
                CubicKeyframe(1 - Self.length, duration: 0.5)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.05)
                LinearKeyframe(1, duration: 0.35)
                LinearKeyframe(0, duration: 0.12)
            }
        }
    }

    struct PulseFrame {
        var offset: CGFloat = 0
        var opacity: Double = 0
    }
}

struct OnboardingFlight: Identifiable, Equatable {
    let id: Int
    let tint: Color
}

/// One photo arcing from the phone to the Mac: it lifts, swells at the top
/// of the arc, and shrinks as it lands.
private struct OnboardingFlightView: View {
    static let duration: TimeInterval = 0.62

    let flight: OnboardingFlight
    let path: OnboardingArc
    @State private var isLaunched = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(flight.tint)
            .overlay {
                Image(systemName: "photo.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 28, height: 28)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .keyframeAnimator(initialValue: FlightFrame(), trigger: isLaunched) { content, frame in
                content
                    .scaleEffect(frame.scale)
                    .rotationEffect(.degrees(frame.rotation))
                    .opacity(frame.opacity)
                    .position(path.point(at: frame.progress))
            } keyframes: { _ in
                KeyframeTrack(\.progress) {
                    CubicKeyframe(1, duration: Self.duration)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.3, duration: Self.duration * 0.45)
                    SpringKeyframe(0.75, duration: Self.duration * 0.55)
                }
                KeyframeTrack(\.rotation) {
                    CubicKeyframe(-14, duration: Self.duration * 0.5)
                    CubicKeyframe(0, duration: Self.duration * 0.5)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.06)
                    LinearKeyframe(1, duration: Self.duration - 0.14)
                    LinearKeyframe(0, duration: 0.08)
                }
            }
            .onAppear { isLaunched = true }
            .allowsHitTesting(false)
    }

    struct FlightFrame {
        var progress: CGFloat = 0
        var scale: CGFloat = 0.7
        var rotation: Double = 0
        var opacity: Double = 0
    }

}

/// A quadratic arc for a flying file.
struct OnboardingArc: Equatable, Sendable {
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint

    /// The point `t` of the way along the arc.
    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
            y: u * u * from.y + 2 * u * t * control.y + t * t * to.y
        )
    }
}

/// A one-shot ring of sparks around the Mac for the finish.
private struct OnboardingSparkleBurst: View {
    let trigger: Int
    private static let count = 10

    var body: some View {
        ZStack {
            ForEach(0..<Self.count, id: \.self) { index in
                let angle = Angle.degrees(Double(index) / Double(Self.count) * 360)
                Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "circle.fill")
                    .font(.system(size: index.isMultiple(of: 2) ? 12 : 5, weight: .bold))
                    .foregroundStyle(index.isMultiple(of: 3) ? OnboardingPalette.warm : .white)
                    .keyframeAnimator(initialValue: BurstFrame(), trigger: trigger) { content, frame in
                        content
                            .scaleEffect(frame.scale)
                            .opacity(frame.opacity)
                            .offset(
                                x: cos(angle.radians) * frame.distance,
                                y: sin(angle.radians) * frame.distance * 0.75
                            )
                    } keyframes: { _ in
                        KeyframeTrack(\.distance) {
                            LinearKeyframe(40, duration: 0.01)
                            SpringKeyframe(118, duration: 0.6, spring: .bouncy)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.4, duration: 0.01)
                            SpringKeyframe(1.2, duration: 0.3)
                            LinearKeyframe(0.6, duration: 0.4)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(1, duration: 0.05)
                            LinearKeyframe(1, duration: 0.35)
                            LinearKeyframe(0, duration: 0.3)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct BurstFrame {
        var distance: CGFloat = 40
        var scale: CGFloat = 0
        var opacity: Double = 0
    }
}
