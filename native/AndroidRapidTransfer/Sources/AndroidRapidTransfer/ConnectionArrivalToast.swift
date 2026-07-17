import AndroidRapidTransferCore
import SwiftUI

/// The "connected" moment: a capsule that springs up over the device browser
/// once the phone's files are ready, its checkmark bouncing and the free
/// space counting up, then drifts away on its own. It never takes clicks.
struct ConnectionArrivalToast: View {
    let arrival: ConnectionArrival
    @State private var hasAppeared = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .motionBounce(value: hasAppeared)
            VStack(alignment: .leading, spacing: 1) {
                Text(arrival.title)
                    .font(.headline)
                    .lineLimit(1)
                if let freeBytes = arrival.freeBytes {
                    FreeSpaceText(bytes: hasAppeared ? freeBytes : 0)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .motion(Motion.gentle.speed(0.6), value: hasAppeared)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .onAppear { hasAppeared = true }
    }
}

/// Free space that counts up to its value when animated, instead of swapping
/// text: the free space "filling in".
private struct FreeSpaceText: View, Animatable {
    var bytes: Int64

    nonisolated var animatableData: Double {
        get { Double(bytes) }
        set { bytes = Int64(newValue.rounded()) }
    }

    var body: some View {
        Text("\(bytes.formatted(.byteCount(style: .file))) free")
    }
}
