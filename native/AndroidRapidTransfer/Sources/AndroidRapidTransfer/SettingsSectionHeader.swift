import SwiftUI

/// A Settings section title with a tinted symbol that bounces when one of the
/// section's settings changes: a small acknowledgement that the change took.
struct SettingsSectionHeader<Trigger: Equatable>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let trigger: Trigger

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
                .motionBounce(value: trigger)
        }
    }
}

extension SettingsSectionHeader where Trigger == Int {
    /// A header that never bounces.
    init(title: LocalizedStringKey, systemImage: String) {
        self.init(title: title, systemImage: systemImage, trigger: 0)
    }
}
