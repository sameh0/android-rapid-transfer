import AndroidRapidTransferCore
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let artDeviceItems = UTType(
        exportedAs: "\(AppIdentity.bundleIdentifier).device-items",
        conformingTo: .data
    )
}

struct DeviceDragPayload: Codable, Sendable, Transferable {
    let sources: [String]
    let storageID: UInt32
    let sessionID: UUID
    let sourceObjectIds: [String: UInt32]?

    init(
        sources: [String],
        storageID: UInt32,
        sessionID: UUID,
        sourceObjectIds: [String: UInt32] = [:]
    ) {
        self.sources = sources
        self.storageID = storageID
        self.sessionID = sessionID
        self.sourceObjectIds = sourceObjectIds.isEmpty ? nil : sourceObjectIds
    }

    static func acceptedItems(
        from payloads: [DeviceDragPayload],
        activeSessionID: UUID?
    ) -> (sources: [String], storageID: UInt32, sourceObjectIds: [String: UInt32])? {
        guard let activeSessionID,
              let firstPayload = payloads.first,
              firstPayload.sessionID == activeSessionID,
              payloads.allSatisfy({
                  $0.sessionID == activeSessionID && $0.storageID == firstPayload.storageID
              }) else { return nil }
        let sources = payloads.flatMap(\.sources)
        guard !sources.isEmpty else { return nil }
        let sourceObjectIds = payloads.reduce(into: [String: UInt32]()) { result, payload in
            result.merge(payload.sourceObjectIds ?? [:]) { _, latest in latest }
        }
        return (sources, firstPayload.storageID, sourceObjectIds)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .artDeviceItems)
    }
}
