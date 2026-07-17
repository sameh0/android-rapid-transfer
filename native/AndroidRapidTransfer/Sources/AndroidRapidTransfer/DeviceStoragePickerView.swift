import AndroidRapidTransferCore
import SwiftUI

/// The storage switcher in the device pane's header: the current storage and
/// how full it is, opening a popover of storage cards to switch between.
struct DeviceStoragePickerView: View {
    @Bindable var model: DeviceBrowserViewModel
    let navigationDisabled: Bool
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            StorageSummaryLabel(storage: selectedStorage)
        }
        .buttonStyle(StorageSummaryButtonStyle())
        .frame(maxWidth: 210)
        .disabled(model.storages.count < 2 || model.isLoading || navigationDisabled)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            StorageCardList(storages: model.storages, selectedID: model.selectedStorageID) { id in
                Task { await model.selectStorage(id: id) }
            } dismiss: {
                isPresented = false
            }
        }
        .help(selectedStorage?.capacitySummary ?? "Storage")
        .accessibilityLabel("Storage")
        .accessibilityValue(selectedStorage.map(Self.accessibilityValue) ?? "")
        .accessibilityHint(model.storages.count > 1 ? "Shows the phone’s storage volumes to switch between" : "")
    }

    private var selectedStorage: DeviceStorage? {
        model.storages.first { $0.id == model.selectedStorageID }
    }

    static func accessibilityValue(_ storage: DeviceStorage) -> String {
        [storage.name, storage.capacitySummary, usageWord(storage)].compactMap(\.self).joined(separator: ", ")
    }

    /// What the capacity bar's colour says, for VoiceOver.
    static func usageWord(_ storage: DeviceStorage) -> String? {
        switch storage.usageLevel {
        case .full: "full"
        case .nearlyFull: "nearly full"
        case .normal, nil: nil
        }
    }
}

/// The header control's face: icon, name, a thin capacity bar and the
/// pop-up chevrons.
private struct StorageSummaryLabel: View {
    let storage: DeviceStorage?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: storage.map(StorageSymbol.name(for:)) ?? "internaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(storage?.name ?? "Storage")
                    .font(.callout)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                if let storage, storage.usedFraction != nil {
                    StorageCapacityBar(storage: storage, height: 3)
                        .frame(width: 64)
                }
            }
            if isEnabled {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .motion(Motion.snappy, value: storage)
    }
}

/// A borderless pop-up look that lights up under the pointer.
private struct StorageSummaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StorageSummaryButtonBody(configuration: configuration)
    }
}

/// The style's body, as a view of its own so it can hold hover state.
private struct StorageSummaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.12 : isHovered && isEnabled ? 0.06 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .onHover { hovering in isHovered = hovering }
            .motion(Motion.snappy, value: isHovered)
    }
}

/// The storage cards: they stagger in, lift under the pointer, and their
/// capacity bars fill on a spring. Choosing one slides the selection ring to
/// it before the popover closes.
private struct StorageCardList: View {
    let storages: [DeviceStorage]
    let selectedID: UInt32?
    let select: (UInt32) -> Void
    let dismiss: () -> Void

    @Namespace private var selectionRing
    @State private var chosenID: UInt32?
    @State private var hasAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage")
                .font(.headline)
                .padding(.horizontal, 4)
            ForEach(Array(storages.enumerated()), id: \.element.id) { index, storage in
                StorageCard(
                    storage: storage,
                    isSelected: storage.id == (chosenID ?? selectedID),
                    fillsBar: hasAppeared,
                    selectionRing: selectionRing
                ) {
                    choose(storage.id)
                }
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 10)
                .motion(Motion.bouncy.delay(0.05 * Double(index)), value: hasAppeared)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { hasAppeared = true }
    }

    private func choose(_ id: UInt32) {
        guard id != (chosenID ?? selectedID) else {
            dismiss()
            return
        }
        withMotion(Motion.snappy) { chosenID = id }
        select(id)
        // Let the ring land on the new card before the popover goes.
        let delay = MotionPolicy.current.duration(Motion.Duration.standard)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            dismiss()
        }
    }
}

private struct StorageCard: View {
    let storage: DeviceStorage
    let isSelected: Bool
    let fillsBar: Bool
    let selectionRing: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: StorageSymbol.name(for: storage))
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(storage.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if storage.usedFraction != nil {
                        StorageCapacityBar(storage: storage, height: 6, isFilled: fillsBar)
                    }
                    Text(storage.capacitySummary ?? "Capacity unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .motionTransition(.scale.combined(with: .opacity))
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.background.secondary)
                    .shadow(color: .black.opacity(isHovered ? 0.14 : 0.04), radius: isHovered ? 6 : 1, y: isHovered ? 3 : 1)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .motionMatchedGeometry(id: "selection", in: selectionRing)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.015 : 1)
        .offset(y: isHovered ? -1 : 0)
        .onHover { hovering in isHovered = hovering }
        .motion(Motion.snappy, value: isHovered)
        .accessibilityLabel(storage.name)
        .accessibilityValue(
            [storage.capacitySummary, DeviceStoragePickerView.usageWord(storage)]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// How full a storage is: accent while there is room, orange when nearly
/// full, red when full.
struct StorageCapacityBar: View {
    let storage: DeviceStorage
    let height: CGFloat
    /// False draws the bar empty, so it can fill on a spring when set.
    var isFilled = true

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(height, proxy.size.width * (isFilled ? fraction : 0)))
                        .opacity(isFilled ? 1 : 0)
                }
        }
        .frame(height: height)
        .motion(Motion.bouncy, value: isFilled)
        .motion(Motion.snappy, value: fraction)
        .accessibilityHidden(true)
    }

    private var fraction: Double {
        storage.usedFraction ?? 0
    }

    private var color: Color {
        switch storage.usageLevel {
        case .full: .red
        case .nearlyFull: .orange
        case .normal, nil: .accentColor
        }
    }
}

enum StorageSymbol {
    static func name(for storage: DeviceStorage) -> String {
        storage.isRemovable ? "sdcard" : "internaldrive"
    }
}
