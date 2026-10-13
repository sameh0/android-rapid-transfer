import AndroidRapidTransferCore
import SwiftUI

/// Troubleshooting & FAQ: the running apps that block the connection, then
/// expandable topic cards, the first one open.
struct HelpCenterView: View {
    /// The topic that explains the apps listed in ``ConflictingAppsCard``.
    static let conflictingAppsTopicID = "interfering-apps"

    @Environment(\.openWindow) private var openWindow
    @State private var expandedTopicIDs: Set<String>
    @State private var conflictingApps: ConflictingAppsModel
    private let topics: [HelpTopic]

    init(topics: [HelpTopic] = HelpContent.topics(), conflictingApps: ConflictingAppsModel? = nil) {
        self.topics = topics
        _expandedTopicIDs = State(initialValue: Set(topics.prefix(1).map(\.id)))
        _conflictingApps = State(
            initialValue: conflictingApps ?? ConflictingAppsModel(provider: WorkspaceRunningApplications())
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SecondaryWindowHeader(
                        title: "Troubleshooting & FAQ",
                        subtitle: "Fixes for the problems people run into most, starting with the most common.",
                        systemImage: "lifepreserver.fill"
                    )
                    .padding(.bottom, 8)
                    ConflictingAppsCard(model: conflictingApps, showDetails: showDetailsAction(proxy))
                        .padding(.bottom, 4)
                        .staggeredAppearance(index: 1)
                    ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                        HelpTopicCard(
                            topic: topic,
                            isExpanded: expandedTopicIDs.contains(topic.id),
                            toggle: { toggle(topic.id) }
                        )
                        .id(topic.id)
                        .staggeredAppearance(index: index + 2)
                    }
                    stillStuck
                        .padding(.top, 8)
                        .staggeredAppearance(index: topics.count + 2)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { conflictingApps.start() }
        .onDisappear { conflictingApps.stop() }
    }

    /// Opens and scrolls to the topic about these apps, when the window has it.
    private func showDetailsAction(_ proxy: ScrollViewProxy) -> (() -> Void)? {
        let id = Self.conflictingAppsTopicID
        guard topics.contains(where: { $0.id == id }) else { return nil }
        return {
            withMotion(Motion.snappy) {
                expandedTopicIDs.insert(id)
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private var stillStuck: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Still stuck?")
                .font(.headline)
            Text("A bug report tells us what went wrong.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Privacy") { openWindow(id: AppWindowID.privacy) }
                .buttonStyle(.link)
            Button("Report a Bug…") { openWindow(id: AppWindowID.reportBug) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private func toggle(_ id: String) {
        withMotion(Motion.snappy) {
            if expandedTopicIDs.contains(id) {
                expandedTopicIDs.remove(id)
            } else {
                expandedTopicIDs.insert(id)
            }
        }
    }
}

/// One topic: a clickable header that springs open to show its sections.
private struct HelpTopicCard: View {
    let topic: HelpTopic
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Image(systemName: topic.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                        .motionBounce(value: isExpanded)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(.tint.opacity(0.12)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title)
                            .font(.headline)
                        Text(topic.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(Text(isExpanded ? "Hides the steps" : "Shows the steps"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(topic.sections) { section in
                        HelpSectionView(section: section, numbersSteps: true)
                    }
                }
                .padding(.leading, 56)
                .padding([.trailing, .bottom], 16)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .motionTransition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.background.secondary)
                .shadow(color: .black.opacity(isHovered || isExpanded ? 0.1 : 0.04), radius: isHovered ? 6 : 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(.separator.opacity(isExpanded ? 0.9 : 0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onHover { isHovered = $0 }
        .motion(Motion.snappy, value: isHovered)
    }
}

/// One help section. Steps are numbered for procedures and bulleted for lists.
struct HelpSectionView: View {
    let section: HelpSection
    let numbersSteps: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.subheadline)
                .bold()
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if numbersSteps {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.tint.opacity(0.12)))
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                    } else {
                        Text("•")
                            .foregroundStyle(.secondary)
                    }
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }
}
