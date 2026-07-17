import AndroidRapidTransferCore
import SwiftUI

/// The words under the onboarding illustration. Each block arrives a beat
/// after the one above it.
struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 10) {
            if let step = page.setupStep {
                Text("Step \(step) of \(OnboardingPage.setupStepCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .staggeredAppearance(index: 0)
            }
            Text(page.title)
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .staggeredAppearance(index: 1)
            Text(page.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .staggeredAppearance(index: 2)
            extras
                .padding(.top, 6)
                .staggeredAppearance(index: 3)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var extras: some View {
        switch page {
        case .welcome:
            HStack(spacing: 10) {
                OnboardingFeatureChip(title: "Fast over USB", systemImage: "bolt.fill")
                OnboardingFeatureChip(title: "Drag and drop with Finder", systemImage: "hand.draw.fill")
                OnboardingFeatureChip(title: "Nothing leaves your Mac", systemImage: "lock.shield.fill")
            }
        case .fileTransfer:
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "If the phone asks “Allow access to phone data?”, tap Allow.",
                    systemImage: "hand.tap.fill"
                )
                Label(
                    "Quit Android File Transfer, Google Drive and other apps that use your phone — only one app can connect to it at a time.",
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460, alignment: .leading)
        case .done:
            Text("Stuck later? Help › Troubleshooting & FAQ has the fixes for common problems.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        case .unlock:
            OnboardingTip(
                text: String(localized: "Keep the screen on until your phone appears in \(AppIdentity.name)."),
                systemImage: "lightbulb.fill"
            )
        case .plugIn:
            OnboardingTip(
                text: String(localized: "Nothing happening? Try a different USB port, or unplug the cable and plug it back in."),
                systemImage: "lightbulb.fill"
            )
        }
    }
}

/// A one-line hint under a setup step.
private struct OnboardingTip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(OnboardingChipLabelStyle(isHovered: false))
    }
}

/// A small tinted capsule naming one thing the app is good at.
private struct OnboardingFeatureChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    @State private var isHovered = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .labelStyle(OnboardingChipLabelStyle(isHovered: isHovered))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.tint.opacity(isHovered ? 0.18 : 0.1)))
            .onHover { isHovered = $0 }
            .motion(Motion.snappy, value: isHovered)
    }
}

private struct OnboardingChipLabelStyle: LabelStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .foregroundStyle(.tint)
                .motionBounce(value: isHovered)
            configuration.title
        }
    }
}

extension OnboardingPage {
    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome to \(AppIdentity.name)")
        case .unlock: String(localized: "Unlock your phone")
        case .plugIn: String(localized: "Plug it in with USB")
        case .fileTransfer: String(localized: "Choose File transfer")
        case .done: String(localized: "You’re all set")
        }
    }

    fileprivate var message: String {
        switch self {
        case .welcome:
            String(localized: "Move photos, videos and files between your Android phone and this Mac. Setup takes three quick steps.")
        case .unlock:
            String(localized: "Unlock the phone and keep it unlocked while it connects. A locked phone keeps its files hidden.")
        case .plugIn:
            String(localized: "Connect the phone to this Mac with a USB cable that carries data — some cables only charge. Plug straight into the Mac rather than an unpowered hub.")
        case .fileTransfer:
            String(localized: "On the phone, tap the “Charging this device via USB” notification and pick File transfer.")
        case .done:
            String(localized: "\(AppIdentity.name) finds your phone as soon as it’s connected. Drag files between the phone and Finder, or open a second pane to see both side by side.")
        }
    }
}
