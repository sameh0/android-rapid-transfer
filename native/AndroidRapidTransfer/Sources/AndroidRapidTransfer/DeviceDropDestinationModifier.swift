import SwiftUI

struct DeviceDropDestinationModifier: ViewModifier {
    let destinationName: String
    /// Finder drops: file URLs.
    let accept: ([URL]) -> Bool
    /// In-app drops from the local pane, uploaded through the same path.
    var acceptLocalItems: (([URL]) -> Bool)?

    func body(content: Content) -> some View {
        content.modifier(
            BrowserDropDestinationModifier<LocalDragPayload>(
                title: BrowserDropTitle(destination: destinationName, rootName: "Phone"),
                acceptFiles: accept,
                acceptPayloads: acceptLocalItems.map { acceptLocalItems in
                    { payloads in
                        guard let urls = LocalDragPayload.acceptedURLs(from: payloads) else {
                            return false
                        }
                        return acceptLocalItems(urls)
                    }
                }
            )
        )
    }
}
