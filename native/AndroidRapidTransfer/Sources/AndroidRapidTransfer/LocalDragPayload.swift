import AndroidRapidTransferCore
import AppKit
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let artLocalItems = UTType(
        exportedAs: "\(AppIdentity.bundleIdentifier).local-items",
        conformingTo: .data
    )
}

/// The app-private payload of a drag that starts in the local pane. Only the
/// device pane accepts it, so a drop back onto the local pane is rejected
/// (a same-pane drop would copy files onto themselves). It mirrors
/// ``DeviceDragPayload``: one
/// pasteboard item carries the whole selection.
struct LocalDragPayload: Codable, Sendable, Transferable {
    let paths: [String]

    static func acceptedURLs(from payloads: [LocalDragPayload]) -> [URL]? {
        let urls = payloads.flatMap(\.paths).map { URL(fileURLWithPath: $0) }
        return urls.isEmpty ? nil : urls
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .artLocalItems)
    }

    /// Eagerly encoded for AppKit dragging sessions, which need a synchronous
    /// `NSPasteboardWriting`.
    @MainActor
    static func makePasteboardItem(paths: [String]) -> NSPasteboardItem? {
        guard !paths.isEmpty,
              let data = try? JSONEncoder().encode(LocalDragPayload(paths: paths)) else { return nil }
        let item = NSPasteboardItem()
        item.setData(
            data,
            forType: NSPasteboard.PasteboardType(UTType.artLocalItems.identifier)
        )
        return item
    }
}
