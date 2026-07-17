import AndroidRapidTransferCore
import SwiftUI

/// What an empty listing says: an empty folder invites a drop, an empty
/// search says nothing matched. The symbol bounces once as it appears.
struct BrowserEmptyStateView: View {
    enum Kind: Equatable {
        case emptyFolder(BrowserPaneKind)
        case noResults(String)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: Kind
    @State private var bounce = 0

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .motionBounce(value: bounce)
                .frame(width: 68, height: 68)
                .background(.tint.opacity(0.1), in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .padding(24)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .onAppear(perform: bounceIfAllowed)
        .onChange(of: kind) { _, _ in bounceIfAllowed() }
    }

    private var symbolName: String {
        switch kind {
        case .emptyFolder: "folder"
        case .noResults: "magnifyingglass"
        }
    }

    var title: String {
        switch kind {
        case .emptyFolder: "Empty Folder"
        case .noResults: "No Results"
        }
    }

    var message: String {
        switch kind {
        case .emptyFolder(.device): "Drag files or folders here to copy them to your phone."
        case .emptyFolder(.local): "Drag items here from your phone to copy them to this Mac."
        case let .noResults(query): "No items match “\(query)”."
        }
    }

    private func bounceIfAllowed() {
        guard !reduceMotion else { return }
        bounce += 1
    }
}
