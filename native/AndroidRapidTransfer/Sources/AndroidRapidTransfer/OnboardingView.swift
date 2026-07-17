import SwiftUI

/// The first-run sheet: a welcome, three setup steps and a finish page.
///
/// Keyboard: Return continues, Esc skips, and the left and right arrow keys
/// move between pages.
struct OnboardingView: View {
    @Bindable var coordinator: OnboardingCoordinator

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeroView(page: coordinator.page)
                .padding(.top, 24)
            ZStack(alignment: .top) {
                OnboardingPageView(page: coordinator.page)
                    .id(coordinator.page)
                    .motionTransition(pageTransition)
            }
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .background(arrowKeyShortcuts)
        // The whole page swaps at once; say where the guide is now.
        .onChange(of: coordinator.page) { _, page in
            AccessibilityNotification.Announcement(page.title).post()
        }
    }

    /// New pages slide in from the side they come from; old ones just fade,
    /// so a change of direction never slides the wrong way.
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: coordinator.isMovingForward ? 40 : -40).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var footer: some View {
        HStack {
            if coordinator.page.isLast {
                Spacer()
                    .frame(width: 1)
            } else {
                Button("Skip") { coordinator.dismiss() }
                    .buttonStyle(.link)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the guide. Help › Getting Started opens it again.")
            }
            Spacer()
            OnboardingStepIndicator(current: coordinator.page) { page in
                withMotion(Motion.snappy) { coordinator.go(to: page) }
            }
            Spacer()
            HStack(spacing: 8) {
                if !coordinator.page.isFirst {
                    Button("Back", action: goBack)
                        .motionTransition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Button(action: advance) {
                    Text(continueTitle)
                        .contentTransition(.interpolate)
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .motion(Motion.snappy, value: coordinator.page.isFirst)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var continueTitle: String {
        switch coordinator.page {
        case .welcome: String(localized: "Get Started")
        case .done: String(localized: "Start Copying")
        case .unlock, .plugIn, .fileTransfer: String(localized: "Continue")
        }
    }

    /// Invisible buttons that give the arrow keys their meaning without
    /// needing keyboard focus inside the sheet.
    private var arrowKeyShortcuts: some View {
        ZStack {
            Button("Previous Page", action: goBack)
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Page") {
                guard !coordinator.page.isLast else { return }
                advance()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            if coordinator.page.isLast {
                Button("Close", action: coordinator.dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func advance() {
        withMotion(Motion.snappy) { coordinator.advance() }
    }

    private func goBack() {
        withMotion(Motion.snappy) { coordinator.goBack() }
    }
}

/// Dots for the pages, the current one stretched into a capsule that springs
/// from dot to dot. Each dot jumps to its page.
struct OnboardingStepIndicator: View {
    let current: OnboardingPage
    let select: (OnboardingPage) -> Void
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingPage.allCases, id: \.self) { page in
                Button {
                    select(page)
                } label: {
                    ZStack {
                        Capsule()
                            .fill(page.rawValue < current.rawValue ? AnyShapeStyle(.tint.opacity(0.45)) : AnyShapeStyle(.quaternary))
                        if page == current {
                            Capsule()
                                .fill(.tint)
                                .motionMatchedGeometry(id: "current", in: indicator)
                        }
                    }
                    .frame(width: page == current ? 22 : 8, height: 8)
                    .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Page \(page.rawValue + 1): \(page.title)"))
                .accessibilityAddTraits(page == current ? .isSelected : [])
            }
        }
        .motion(Motion.bouncy, value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Page \(current.rawValue + 1) of \(OnboardingPage.allCases.count)"))
    }
}
