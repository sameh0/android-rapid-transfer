import Foundation

/// A quick-access destination for the local pane: Home, Desktop, Downloads,
/// removable disks and the filesystem root.
public struct LocalFavorite: Identifiable, Hashable, Sendable {
    public let label: String
    public let systemImage: String
    public let path: String

    public var id: String { path }

    public init(label: String, systemImage: String, path: String) {
        self.label = label
        self.systemImage = systemImage
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    }

    #if !canImport(Darwin)
    public static var standard: [LocalFavorite] {
        let directories = XDGUserDirectories()
        return [
            LocalFavorite(label: "Home", systemImage: "house", path: directories.home.path),
            LocalFavorite(
                label: "Desktop",
                systemImage: "menubar.dock.rectangle",
                path: directories.desktop.path
            ),
            LocalFavorite(
                label: "Downloads",
                systemImage: "arrow.down.circle",
                path: directories.downloads.path
            ),
            LocalFavorite(
                label: "Removable Disks",
                systemImage: "externaldrive",
                path: XDGUserDirectories.removableMediaRoot()
            ),
            LocalFavorite(label: "Root", systemImage: "internaldrive", path: "/"),
        ]
    }
    #else
    public static var standard: [LocalFavorite] {
        [
            LocalFavorite(label: "Home", systemImage: "house", path: URL.homeDirectory.path),
            LocalFavorite(
                label: "Desktop",
                systemImage: "menubar.dock.rectangle",
                path: URL.desktopDirectory.path
            ),
            LocalFavorite(
                label: "Downloads",
                systemImage: "arrow.down.circle",
                path: URL.downloadsDirectory.path
            ),
            LocalFavorite(label: "Removable Disks", systemImage: "externaldrive", path: "/Volumes"),
            LocalFavorite(label: "Root", systemImage: "internaldrive", path: "/"),
        ]
    }
    #endif
}
