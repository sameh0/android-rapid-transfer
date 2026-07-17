import AndroidRapidTransferCore
import SwiftUI

/// The folder path as clickable segments. Going deeper slides the new
/// segment in and glides the "you are here" pill onto it; going up does the
/// reverse. The bar keeps the deepest segment in view.
struct BreadcrumbBarView<Model: BrowserPaneModel>: View {
    @Bindable var model: Model
    let paneKind: BrowserPaneKind
    let navigationDisabled: Bool
    @Namespace private var pill

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 1) {
                    ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, segment in
                        HStack(spacing: 1) {
                            if index > 0 {
                                Image(systemName: "chevron.compact.right")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            BreadcrumbSegmentView(
                                segment: segment,
                                systemImage: index == 0 ? rootSystemImage : nil,
                                isCurrent: segment.location == model.currentLocation,
                                isEnabled: !model.isLoading && !navigationDisabled,
                                pill: pill,
                                navigate: { navigate(to: segment) }
                            )
                        }
                        .id(segment.id)
                        .motionTransition(.offset(x: -14).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .motion(Motion.snappy, value: model.breadcrumbs)
            .onChange(of: model.currentLocation, initial: true) { _, _ in
                guard let last = model.breadcrumbs.last else { return }
                withMotion(Motion.snappy) {
                    proxy.scrollTo(last.id, anchor: .trailing)
                }
            }
        }
        .background(.bar)
    }

    private var rootSystemImage: String {
        switch paneKind {
        case .device: "smartphone"
        case .local: "internaldrive"
        }
    }

    private func navigate(to segment: BreadcrumbSegment) {
        Task { await model.navigate(to: segment) }
    }
}

private struct BreadcrumbSegmentView: View {
    let segment: BreadcrumbSegment
    let systemImage: String?
    let isCurrent: Bool
    let isEnabled: Bool
    let pill: Namespace.ID
    let navigate: () -> Void
    @State private var isHovered = false

    var body: some View {
        Group {
            if isCurrent {
                label
                    .fontWeight(.semibold)
                    .accessibilityValue("Current folder")
            } else {
                Button(action: navigate) { label }
                    .buttonStyle(.plain)
                    .foregroundStyle(isHovered && isEnabled ? .primary : .secondary)
                    .disabled(!isEnabled)
                    .onHover { isHovered = $0 }
                    .help("Go to \(segment.label)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            if isCurrent {
                Capsule()
                    .fill(.quaternary)
                    .motionMatchedGeometry(id: "current", in: pill)
            } else if isHovered, isEnabled {
                Capsule()
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .motion(Motion.snappy, value: isHovered)
    }

    private var label: some View {
        Group {
            if let systemImage {
                Label(segment.label, systemImage: systemImage)
            } else {
                Text(segment.label)
            }
        }
        .lineLimit(1)
    }
}
