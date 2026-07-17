import AndroidRapidTransferCore
import AppKit
import SwiftUI

/// The About window. The icon springs in and catches the light once; click it
/// to see that again. Clicking the version copies a one-line build
/// description for bug reports.
struct AboutView: View {
    private let info = AboutInfo.current
    @Environment(\.openWindow) private var openWindow
    @State private var didCopyVersion = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            AboutIconView()
                .padding(.top, 28)
                .staggeredAppearance(index: 0, animation: Motion.celebrate)
            Text(info.name)
                .font(.title2.weight(.bold))
                .padding(.top, 14)
                .staggeredAppearance(index: 2)
            Text("Fast file transfer between Android and Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                .staggeredAppearance(index: 3)
            versionButton
                .padding(.top, 10)
                .staggeredAppearance(index: 4)
            HStack(spacing: 10) {
                Button("Acknowledgements") { openWindow(id: AppWindowID.acknowledgements) }
                Button("GitHub") { NSWorkspace.shared.open(AppIdentity.repositoryURL) }
            }
            .controlSize(.small)
            .padding(.top, 18)
            .staggeredAppearance(index: 5)
            VStack(spacing: 3) {
                Text(info.copyright)
                Text("Android is a trademark of Google LLC.")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .staggeredAppearance(index: 6)
        }
        .padding(.horizontal, 28)
        .frame(width: 340)
        .onDisappear { copyResetTask?.cancel() }
    }

    private var versionButton: some View {
        Button(action: copyVersion) {
            HStack(spacing: 5) {
                Text(info.versionLine)
                    .monospacedDigit()
                Image(systemName: didCopyVersion ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(didCopyVersion ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help("Copy the version for a bug report")
        .accessibilityLabel(didCopyVersion ? Text("Version copied") : Text(info.versionLine))
        .accessibilityHint(Text("Copies the version for a bug report"))
    }

    private func copyVersion() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            info.diagnosticsLine(macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString),
            forType: .string
        )
        withMotion(Motion.bouncy) { didCopyVersion = true }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withMotion(Motion.gentle) { didCopyVersion = false }
        }
    }
}

/// The app icon with a one-shot sheen across it and a playful tilt, replayed
/// on click.
private struct AboutIconView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plays = 0
    @State private var isHovered = false

    var body: some View {
        let icon = Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 128, height: 128)

        icon
            .overlay {
                // A band of light sweeping across, clipped to the icon's shape.
                KeyframeAnimator(initialValue: SheenFrame(), trigger: plays) { frame in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.55), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 48)
                    .rotationEffect(.degrees(20))
                    .offset(x: frame.offset)
                    .opacity(frame.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.offset) {
                        LinearKeyframe(-110, duration: 0.2)
                        CubicKeyframe(110, duration: 0.7)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0, duration: 0.2)
                        LinearKeyframe(1, duration: 0.1)
                        LinearKeyframe(1, duration: 0.45)
                        LinearKeyframe(0, duration: 0.15)
                    }
                }
                .mask(icon)
                .allowsHitTesting(false)
            }
            .keyframeAnimator(initialValue: TiltFrame(), trigger: plays) { content, frame in
                content
                    .rotationEffect(.degrees(frame.rotation))
                    .scaleEffect(frame.scale)
            } keyframes: { _ in
                KeyframeTrack(\.rotation) {
                    SpringKeyframe(-6, duration: 0.18)
                    SpringKeyframe(4, duration: 0.18)
                    SpringKeyframe(0, duration: 0.3)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.06, duration: 0.2)
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                }
            }
            .scaleEffect(isHovered ? 1.03 : 1)
            .shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 10 : 6, y: isHovered ? 5 : 3)
            .motion(Motion.snappy, value: isHovered)
            .onHover { isHovered = $0 }
            .onTapGesture(perform: play)
            .task {
                try? await Task.sleep(for: .seconds(0.35))
                play()
            }
            .accessibilityLabel(Text("\(AppIdentity.name) icon"))
            .accessibilityAddTraits(.isImage)
    }

    private func play() {
        guard !reduceMotion else { return }
        plays += 1
    }

    struct SheenFrame {
        var offset: CGFloat = -110
        var opacity: Double = 0
    }

    struct TiltFrame {
        var rotation: Double = 0
        var scale: CGFloat = 1
    }
}
