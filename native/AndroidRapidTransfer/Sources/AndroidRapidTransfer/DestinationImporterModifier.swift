import SwiftUI
import UniformTypeIdentifiers

extension View {
    func destinationImporter(
        isPresented: Binding<Bool>,
        onPick: @escaping (URL) -> Void
    ) -> some View {
        modifier(
            DestinationImporterModifier(
                isPresented: isPresented,
                onPick: onPick
            )
        )
    }
}

private struct DestinationImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (URL) -> Void

    @State private var errorMessage = ""
    @State private var isShowingError = false

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false,
                onCompletion: handleSelection
            )
            .alert("Destination Error", isPresented: $isShowingError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
    }

    private func handleSelection(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let destination = urls.first else { return }
            onPick(destination)
        case let .failure(error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }
}
