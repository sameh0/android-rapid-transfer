import AndroidRapidTransferCore
import SwiftUI

/// What the device pane shows while no phone is connected: three steps to
/// connect one, with the step to do next highlighted in turn while the
/// window is live.
struct NoDeviceView: View {
    let retry: () -> Void
    let showConnectionHelp: () -> Void
    @State private var showsShortcuts = false

    var body: some View {
        VStack(spacing: 18) {
            ConnectionMessageView(
                title: "Connect your Android phone",
                message: "\(AppIdentity.name) finds your phone as soon as it’s ready."
            )
            ConnectionStepsView()
            VStack(spacing: 10) {
                ConnectionRetryButton(action: retry)
                ConnectionHelpLinks(showConnectionHelp: showConnectionHelp)
            }
            DisclosureGroup("Keyboard shortcuts", isExpanded: shortcutsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(ShortcutHelp.groups()) { group in
                            ShortcutScopeView(group: group)
                        }
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }
            .frame(maxWidth: 440)
            .padding(.top, 6)
        }
    }

    private var shortcutsExpanded: Binding<Bool> {
        Binding(
            get: { showsShortcuts },
            set: { expanded in withMotion(Motion.snappy) { showsShortcuts = expanded } }
        )
    }
}

/// Plug in, unlock, choose File transfer. The steps stagger in, then the
/// highlight walks through them — each symbol bouncing as its turn comes —
/// while the window is live and has not sat idle for long. Under Reduce Motion they simply sit
/// there, numbered.
private struct ConnectionStepsView: View {
    @Environment(\.motionAllowsIdleLoops) private var isLive
    @State private var hasAppeared = false
    @State private var highlighted: Int?
    @State private var bounces = Array(repeating: 0, count: Self.steps.count)

    private static let steps: [(symbol: String, text: String)] = [
        ("cable.connector", "Plug your phone into this Mac"),
        ("lock.open", "Unlock it, and keep it unlocked"),
        ("hand.tap", "Choose File transfer if Android asks how to use USB")
    ]
    /// How long each step stays highlighted.
    private static let dwell: Duration = .milliseconds(2200)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.steps.indices, id: \.self) { index in
                row(index)
                    .opacity(hasAppeared ? 1 : 0)
                    .offset(y: hasAppeared ? 0 : 6)
                    .motion(Motion.bouncy.delay(0.06 * Double(index + 1)), value: hasAppeared)
            }
        }
        .frame(maxWidth: 380, alignment: .leading)
        .onAppear { hasAppeared = true }
        .task(id: isLive) { await walkThroughSteps() }
    }

    private func row(_ index: Int) -> some View {
        let isHighlighted = highlighted == index
        return HStack(spacing: 12) {
            Image(systemName: Self.steps[index].symbol)
                .font(.title3)
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                .motionBounce(value: bounces[index])
                .frame(width: 28)
            Text(Self.steps[index].text)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.1 : 0))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index + 1): \(Self.steps[index].text)")
    }

    private func walkThroughSteps() async {
        guard isLive else {
            withMotion(Motion.gentle) { highlighted = nil }
            return
        }
        // Let the rows land before the walk starts.
        guard (try? await Task.sleep(for: .milliseconds(700))) != nil else { return }
        var index = highlighted.map { ($0 + 1) % Self.steps.count } ?? 0
        while !Task.isCancelled {
            withMotion(Motion.gentle) { highlighted = index }
            bounces[index] += 1
            guard (try? await Task.sleep(for: Self.dwell)) != nil else { return }
            index = (index + 1) % Self.steps.count
        }
    }
}
