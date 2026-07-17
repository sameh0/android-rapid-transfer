import SwiftUI

/// Drop handling for a browser pane, with its feedback: while a drag hovers,
/// the pane glows and shows where the items will land; an accepted drop gets
/// a short "absorbed" confirmation, a refused one a gentle shake.
///
/// Files from Finder arrive as URLs; `Payload` is the other pane's in-app
/// drag. `acceptPayloads` nil means this pane takes only files.
struct BrowserDropDestinationModifier<Payload: Transferable>: ViewModifier {
    let title: BrowserDropTitle
    let acceptFiles: ([URL]) -> Bool
    let acceptPayloads: (([Payload]) -> Bool)?
    @State private var isTargetedByFiles = false
    @State private var isTargetedByPayloads = false
    @State private var acceptedDrops = 0
    @State private var rejectedDrops = 0

    func body(content: Content) -> some View {
        content
            .motionShake(trigger: rejectedDrops)
            .dropDestination(
                for: URL.self,
                action: { urls, _ in record(acceptFiles(urls)) },
                isTargeted: { isTargetedByFiles = $0 }
            )
            .dropDestination(
                for: Payload.self,
                action: { payloads, _ in
                    guard let acceptPayloads else { return false }
                    return record(acceptPayloads(payloads))
                },
                isTargeted: { isTargetedByPayloads = $0 && acceptPayloads != nil }
            )
            .overlay {
                BrowserDropOverlay(
                    title: title,
                    isTargeted: isTargetedByFiles || isTargetedByPayloads,
                    acceptedDrops: acceptedDrops
                )
            }
    }

    private func record(_ accepted: Bool) -> Bool {
        if accepted {
            acceptedDrops += 1
        } else {
            rejectedDrops += 1
        }
        return accepted
    }
}

/// "Copy to Camera" while hovering, "Copying to Camera" once dropped.
struct BrowserDropTitle: Equatable {
    /// Where a drop lands: "Camera", or the fallback at a volume's root.
    let destinationName: String

    /// - Parameters:
    ///   - destination: The pane's current folder path.
    ///   - rootName: What to call the root, where the path has no name.
    init(destination: String, rootName: String) {
        let folderName = URL(fileURLWithPath: destination).lastPathComponent
        destinationName = folderName.isEmpty || destination == "/" ? rootName : folderName
    }

    var hover: String { "Copy to \(destinationName)" }
    var confirmation: String { "Copying to \(destinationName)" }
}

private struct BrowserDropOverlay: View {
    let title: BrowserDropTitle
    let isTargeted: Bool
    let acceptedDrops: Int
    @State private var showsConfirmation = false

    var body: some View {
        ZStack {
            if isTargeted {
                BrowserDropTargetHighlight(title: title.hover)
                    .motionTransition(.scale(scale: 1.03).combined(with: .opacity))
            }
            if showsConfirmation {
                BrowserDropConfirmation(title: title.confirmation)
                    .motionTransition(
                        .asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity),
                            removal: .scale(scale: 0.85).combined(with: .opacity)
                        )
                    )
            }
        }
        .motion(Motion.bouncy, value: isTargeted)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: acceptedDrops) {
            guard acceptedDrops > 0 else { return }
            withMotion(Motion.celebrate) { showsConfirmation = true }
            try? await Task.sleep(for: .milliseconds(900))
            withMotion(Motion.gentle) { showsConfirmation = false }
        }
    }
}

struct BrowserDropTargetHighlight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    @State private var dashPhase: CGFloat = 0
    @State private var arrowBounce = 0

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [8, 6], dashPhase: dashPhase)
                )
                .padding(8)
            Label {
                Text(title)
            } icon: {
                Image(systemName: "arrow.down.doc.fill")
                    .motionBounce(value: arrowBounce)
                    .foregroundStyle(.tint)
            }
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .onAppear {
            guard !reduceMotion else { return }
            arrowBounce += 1
            withMotion(Motion.marchingAnts) { dashPhase = -14 }
        }
    }
}

struct BrowserDropConfirmation: View {
    let title: String
    @State private var bounce = 0

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .motionBounce(value: bounce)
        }
        .font(.headline)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .onAppear { bounce += 1 }
    }
}
