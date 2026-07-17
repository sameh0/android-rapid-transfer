import SwiftUI

/// The title block shared by the Help, Keyboard Shortcuts, Privacy, Report a
/// Bug and Acknowledgements windows: a tinted symbol tile that bounces once
/// when the window opens, a title and a one-line explanation.
struct SecondaryWindowHeader: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let systemImage: String

    @State private var hasAppeared = false

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, systemImage: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    /// For subtitles built from runtime values, such as the app's name.
    init(title: LocalizedStringKey, subtitle: String, systemImage: String) {
        self.init(title: title, subtitle: LocalizedStringKey(subtitle), systemImage: systemImage)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .motionBounce(value: hasAppeared)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 4, y: 2)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            // After the window has settled, so the bounce is seen.
            try? await Task.sleep(for: .seconds(0.25))
            hasAppeared = true
        }
    }
}
