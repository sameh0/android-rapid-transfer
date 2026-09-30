import Foundation

@MainActor
public protocol DeviceTransferPaneModel: BrowserPaneModel {
    var selectedStorageID: UInt32? { get }

    func existingPaths(_ paths: [String], storageID: UInt32) async throws -> Set<String>

    /// Lists a single device directory without disturbing the pane's own
    /// navigation state. ``DeviceFolderScanner`` builds its recursive walk on
    /// top of this. Implementations must not apply the browser's hidden-files
    /// preference because ``ScanExclusionRules`` is the scan's only exclusion
    /// authority.
    func listDirectoryForScan(_ path: String, storageID: UInt32) async throws -> [BrowserEntry]
}

public extension DeviceTransferPaneModel {
    func existingPaths(_ paths: [String], storageID: UInt32) async throws -> Set<String> {
        let availablePaths = Set(entries.map(\.location))
        return Set(paths.filter(availablePaths.contains))
    }

    /// Serves the listing from the already-loaded entries, matching on parent
    /// path. Models backed by a real device override this to hit the provider.
    func listDirectoryForScan(_ path: String, storageID: UInt32) async throws -> [BrowserEntry] {
        entries.filter { entry in
            URL(fileURLWithPath: entry.location).deletingLastPathComponent().path == path
        }
    }
}
