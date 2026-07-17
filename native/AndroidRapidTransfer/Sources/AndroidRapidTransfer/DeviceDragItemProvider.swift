import AppKit
import UniformTypeIdentifiers

@MainActor
enum DeviceDragItemProvider {
    /// Eagerly encoded payload for AppKit-driven dragging sessions
    /// (`NSDraggingItem` requires a synchronous `NSPasteboardWriting`).
    static func makePasteboardItem(
        sources: [String],
        storageID: UInt32,
        sessionID: UUID,
        sourceObjectIds: [String: UInt32] = [:]
    ) -> NSPasteboardItem? {
        let payload = DeviceDragPayload(
            sources: sources,
            storageID: storageID,
            sessionID: sessionID,
            sourceObjectIds: sourceObjectIds
        )
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let item = NSPasteboardItem()
        item.setData(
            data,
            forType: NSPasteboard.PasteboardType(UTType.artDeviceItems.identifier)
        )
        return item
    }
}
