import AndroidRapidTransferCore
import SwiftUI

struct BrowserStatusBarView<Model: BrowserPaneModel>: View {
    let model: Model

    var body: some View {
        let summary = BrowserStatusSummary(
            itemCount: model.entries.count,
            selectedEntries: model.selectedEntries,
            capacity: model.capacity
        )
        HStack(spacing: 6) {
            Text(summary.itemsText)
                .contentTransition(.numericText(value: Double(summary.itemCount)))
            if let selectionText = summary.selectionText {
                Text("· \(selectionText)")
                    .contentTransition(.numericText(value: Double(summary.selectedCount)))
                    .motionTransition(.offset(x: -6).combined(with: .opacity))
            }
            Spacer(minLength: 12)
            if let usedFraction = summary.usedFraction {
                BrowserCapacityGauge(usedFraction: usedFraction)
            }
            Text(summary.capacityText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .motion(Motion.snappy, value: summary)
        .padding(.horizontal)
        .padding(.vertical, 5)
        .background(.bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityText)
    }
}

/// A slim used-space bar that turns orange, then red, as the disk fills.
private struct BrowserCapacityGauge: View {
    let usedFraction: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 44, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .frame(width: max(5, 44 * usedFraction))
            }
            .accessibilityHidden(true)
    }

    /// The same thresholds as the storage cards (``StorageUsageLevel``).
    private var tint: Color {
        switch StorageUsageLevel(usedFraction: usedFraction) {
        case .full: .red
        case .nearlyFull: .orange
        case .normal: .accentColor
        }
    }
}

/// The status bar's wording, kept apart from the view so it can be tested.
struct BrowserStatusSummary: Equatable {
    let itemCount: Int
    let selectedCount: Int
    /// Total size of the selected files; folders have no known size.
    let selectedBytes: Int64?
    let capacity: BrowserCapacity?

    init(itemCount: Int, selectedEntries: [BrowserEntry], capacity: BrowserCapacity?) {
        self.itemCount = itemCount
        selectedCount = selectedEntries.count
        let sizes = selectedEntries.compactMap(\.size)
        selectedBytes = sizes.isEmpty ? nil : sizes.reduce(0, +)
        self.capacity = capacity
    }

    var itemsText: String {
        "\(itemCount.formatted()) \(itemCount == 1 ? "item" : "items")"
    }

    /// "3 selected (12.4 MB)", or nil with nothing selected.
    var selectionText: String? {
        guard selectedCount > 0 else { return nil }
        let count = "\(selectedCount.formatted()) selected"
        guard let selectedBytes else { return count }
        return "\(count) (\(selectedBytes.formatted(.byteCount(style: .file))))"
    }

    var capacityText: String {
        guard let capacity else { return "Free space unavailable" }
        return "\(capacity.formattedFreeBytes) free of \(capacity.formattedTotalBytes)"
    }

    /// Used share of the volume, 0...1, when its size is known.
    var usedFraction: Double? {
        guard let capacity, capacity.totalBytes > 0 else { return nil }
        let used = Double(capacity.totalBytes - capacity.freeBytes) / Double(capacity.totalBytes)
        return min(max(used, 0), 1)
    }

    /// One sentence for VoiceOver, including what the gauge's colour says:
    /// "12 items, 3 selected (12.4 MB), 1.2 GB free of 128 GB, nearly full".
    var accessibilityText: String {
        var parts = [itemsText]
        if let selectionText { parts.append(selectionText) }
        parts.append(capacityText)
        switch usedFraction.map(StorageUsageLevel.init(usedFraction:)) {
        case .full: parts.append("full")
        case .nearlyFull: parts.append("nearly full")
        case .normal, nil: break
        }
        return parts.joined(separator: ", ")
    }
}
