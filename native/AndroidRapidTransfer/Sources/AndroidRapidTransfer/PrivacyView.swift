import AndroidRapidTransferCore
import SwiftUI

struct PrivacyView: View {
    private let sections = PrivacyContent.sections()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SecondaryWindowHeader(
                    title: "Privacy",
                    subtitle: "Your files move only between this Mac and your phone.",
                    systemImage: "hand.raised.fill"
                )
                .padding(.bottom, 8)
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: Self.systemImage(for: section.id))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(.tint.opacity(0.12)))
                            .accessibilityHidden(true)
                        HelpSectionView(section: section, numbersSteps: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .cardSurface()
                    .staggeredAppearance(index: index + 1)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func systemImage(for sectionID: String) -> String {
        switch sectionID {
        case "no-tracking": "eye.slash.fill"
        case "update-checks": "arrow.triangle.2.circlepath"
        case "stored-locally": "internaldrive.fill"
        case "bug-reports": "ladybug.fill"
        case "links": "link"
        default: "lock.fill"
        }
    }
}
