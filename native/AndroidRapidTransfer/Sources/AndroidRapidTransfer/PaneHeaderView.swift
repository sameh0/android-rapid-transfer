import SwiftUI

struct PaneHeaderView<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack {
            // Morphs rather than snaps when the title changes, e.g. from the
            // generic device name to the phone's own once it has loaded.
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .contentTransition(.interpolate)
                .motion(Motion.snappy, value: title)
            Spacer()
            accessory
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
