import AndroidRapidTransferCore
import SwiftUI

/// The floating "Opening Camera… 1,204 of 2,003 items" card shown while a
/// folder loads. It appears only after ``appearanceDelay``, so the common
/// quick load never flashes it, and the count ticks as the phone reports.
struct BrowserLoadingIndicator: View {
    static let appearanceDelay: Duration = .milliseconds(200)

    let progress: BrowserLoadingProgress?

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = progress?.fractionCompleted, progress?.itemCount != nil {
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .motion(Motion.snappy, value: fraction)
            } else {
                ProgressView()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(for: progress))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = Self.detail(for: progress) {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(progress?.itemsRead ?? 0)))
                        .motion(Motion.snappy, value: progress?.itemsRead)
                }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: 260)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    static func title(for progress: BrowserLoadingProgress?) -> String {
        guard let name = progress?.folderName else { return "Loading…" }
        return "Opening \(name)…"
    }

    /// "1,204 of 2,003 items", once the phone has said how many there are.
    static func detail(for progress: BrowserLoadingProgress?) -> String? {
        guard let progress, let count = progress.itemCount, count > 0 else { return nil }
        let read = progress.itemsRead ?? 0
        return "\(read.formatted()) of \(count.formatted()) \(count == 1 ? "item" : "items")"
    }
}

/// Placeholder rows or tiles for a pane that has never listed anything yet,
/// breathing softly until the first listing lands.
struct BrowserSkeletonView: View {
    /// The breathing stops while the window is hidden, inactive or in the
    /// background, and under Reduce Motion.
    @Environment(\.motionIsLive) private var isLive
    let viewMode: BrowserViewMode

    /// Fixed so the placeholder looks like a listing, not noise.
    private static let nameWidths: [CGFloat] = [
        0.52, 0.38, 0.61, 0.44, 0.33, 0.57, 0.47, 0.29, 0.55, 0.4, 0.5, 0.36
    ]

    var body: some View {
        Group {
            if !isLive {
                placeholder
            } else {
                placeholder.phaseAnimator([0.55, 1.0]) { content, opacity in
                    content.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    @ViewBuilder
    private var placeholder: some View {
        switch viewMode {
        case .list:
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Self.nameWidths.enumerated()), id: \.offset) { _, width in
                        HStack(spacing: 8) {
                            bar(width: 16, height: 16, radius: 4)
                            bar(width: max(60, proxy.size.width * width * 0.6), height: 9)
                            Spacer(minLength: 12)
                            bar(width: 44, height: 9)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 24)
                    }
                }
                .padding(.top, 30)
            }
        case .grid:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(Array(Self.nameWidths.prefix(8).enumerated()), id: \.offset) { _, width in
                    VStack(spacing: 8) {
                        bar(width: 56, height: 56, radius: 10)
                        bar(width: 90 * width + 30, height: 9)
                    }
                    .frame(maxWidth: .infinity, minHeight: 124, alignment: .top)
                    .padding(8)
                }
            }
            .padding()
        }
    }

    private func bar(width: CGFloat, height: CGFloat, radius: CGFloat = 4.5) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.quaternary)
            .frame(width: width, height: height)
    }
}
