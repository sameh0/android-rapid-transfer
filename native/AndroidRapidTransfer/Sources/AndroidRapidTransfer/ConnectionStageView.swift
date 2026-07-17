import AndroidRapidTransferCore
import SwiftUI

/// The layout shared by every "not browsing yet" screen of the device pane:
/// the connection illustration, and that screen's text and actions below it.
///
/// The illustration keeps its identity across screens so it morphs from one
/// state to the next; only the content below cross-fades, keyed on `phase`.
struct ConnectionStageView<Content: View>: View {
    let illustration: ConnectionIllustrationView.Mode
    let phase: ConnectionPanePhase.Kind
    var failureCount = 0
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    ConnectionIllustrationView(mode: illustration, failureCount: failureCount)
                    // A ZStack, so the outgoing and incoming content overlap
                    // while they cross-fade instead of stacking.
                    ZStack {
                        content
                            .id(phase)
                            .motionTransition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 8)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .motion(Motion.gentle, value: phase)
        .motionLiveness(rearmingOn: phase)
    }
}

/// A screen's headline and explanation, in the style of
/// `ContentUnavailableView`.
struct ConnectionMessageView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title2)
                .bold()
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Retry, with the arrow spinning once per click.
struct ConnectionRetryButton: View {
    var isProminent = false
    let action: () -> Void
    @State private var spins = 0

    var body: some View {
        if isProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            withMotion(Motion.bouncy) { spins += 1 }
            action()
        } label: {
            Label {
                Text("Retry")
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(Double(spins) * 360))
            }
        }
        .controlSize(.large)
        .help("Try connecting to the phone again")
    }
}

/// The help links offered on every connection screen.
struct ConnectionHelpLinks: View {
    let showConnectionHelp: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 16) {
            Button("Connection help", action: showConnectionHelp)
            Button("Troubleshooting") { openWindow(id: AppWindowID.help) }
        }
        .buttonStyle(.link)
    }
}
