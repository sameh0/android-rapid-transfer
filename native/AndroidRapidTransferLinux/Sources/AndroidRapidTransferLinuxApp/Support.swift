import ARTGtk
import AndroidRapidTransferCore
import Foundation

// Small helpers shared by the app's views.

extension GObjectRef {
    /// Configures the object inline: `Label("x").then { $0.wraps = true }`.
    @discardableResult
    func then(_ body: (Self) -> Void) -> Self {
        body(self)
        return self
    }
}

/// Calls `changed` whenever the value `read` returns changes (not for the
/// initial value unless `initial` is set): SwiftUI's `onChange` on top of
/// ``ObservationBinding``. Keep the returned object alive.
@MainActor
final class ChangeObserver<Value: Equatable> {
    private var binding: ObservationBinding?
    private var last: Value?

    init(initial: Bool = false, _ read: @escaping @MainActor () -> Value, changed: @escaping @MainActor (Value) -> Void) {
        var isFirst = true
        binding = ObservationBinding { [weak self] in
            let value = read()
            guard let self else { return }
            defer { isFirst = false }
            guard value != self.last else { return }
            self.last = value
            if !isFirst || initial { changed(value) }
        }
    }

    func cancel() { binding?.cancel() }
}

/// Keeps observers and other helpers alive for an owner's lifetime.
@MainActor
final class ObserverBag {
    private var items: [AnyObject] = []
    func add(_ item: AnyObject) { items.append(item) }

    func onChange<Value: Equatable>(initial: Bool = false, _ read: @escaping @MainActor () -> Value, _ changed: @escaping @MainActor (Value) -> Void) {
        items.append(ChangeObserver(initial: initial, read, changed: changed))
    }
}

/// Keeps a dialog's controller object alive while the dialog is open.
@MainActor
enum OpenDialogs {
    private static var controllers: [ObjectIdentifier: AnyObject] = [:]

    static func keep(_ controller: AnyObject, while dialog: Dialog) {
        let id = ObjectIdentifier(controller)
        controllers[id] = controller
        dialog.onClosed { controllers[id] = nil }
    }

    static func count<T: AnyObject>(of type: T.Type) -> Int {
        controllers.values.filter { $0 is T }.count
    }

    static func first<T: AnyObject>(of type: T.Type) -> T? {
        controllers.values.lazy.compactMap { $0 as? T }.first
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 1 else { return "under a second" }
        return Duration.seconds(interval).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    /// Escapes text for Pango markup.
    static func markup(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Themed icons for browser entries, from the file name's content type.
@MainActor
enum EntryIcons {
    private static var cache: [String: [String]] = [:]

    static func names(for entry: BrowserEntry) -> [String] {
        names(forName: entry.name, isDirectory: entry.isDirectory)
    }

    static func names(forName name: String, isDirectory: Bool) -> [String] {
        if isDirectory { return ["folder"] }
        // Keyed by extension: the guess reads only the name, and rows rebind often.
        let ext = (name as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? name : ext
        if let cached = cache[key] { return cached }
        let names = ContentType.iconNames(of: ContentType.guess(fileName: name)) + ["text-x-generic"]
        if cache.count < 2_000 { cache[key] = names }
        return names
    }

    static func typeDescription(for entry: BrowserEntry) -> String {
        entry.isDirectory ? "Folder" : ContentType.description(of: ContentType.guess(fileName: entry.name))
    }
}

/// Opens local files with their default application (Core's hook).
@MainActor
struct DesktopFileOpener: LocalFileOpening {
    func open(_ url: URL) {
        Launcher.open(path: url.path)
    }
}

extension LocalFavorite {
    /// The GNOME icon for a favourite.
    var iconName: String {
        switch systemImage {
        case "house": "user-home-symbolic"
        case "menubar.dock.rectangle": "user-desktop-symbolic"
        case "arrow.down.circle": "folder-download-symbolic"
        case "externaldrive": "drive-removable-media-symbolic"
        case "internaldrive": "drive-harddisk-symbolic"
        case "doc": "folder-documents-symbolic"
        case "photo": "folder-pictures-symbolic"
        case "music.note": "folder-music-symbolic"
        case "film": "folder-videos-symbolic"
        default: "folder-symbolic"
        }
    }

    /// Core's standard favourites plus the other XDG folders, in the order
    /// GNOME Files lists them.
    static var linuxStandard: [LocalFavorite] {
        let directories = XDGUserDirectories()
        let base = LocalFavorite.standard
        let extras = [
            LocalFavorite(label: "Documents", systemImage: "doc", path: directories.documents.path),
            LocalFavorite(label: "Pictures", systemImage: "photo", path: directories.pictures.path),
            LocalFavorite(label: "Music", systemImage: "music.note", path: directories.music.path),
            LocalFavorite(label: "Videos", systemImage: "film", path: directories.videos.path),
        ].filter { favorite in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: favorite.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        // Home, Desktop, Downloads, then the XDG folders, then disks and root.
        let head = base.prefix(3)
        let tail = base.dropFirst(3)
        return Array(head) + extras + Array(tail)
    }
}

extension AppShortcut {
    /// The GTK accelerator for the shortcut: ⌘ becomes Ctrl on Linux.
    var gtkAccelerator: String {
        var result = ""
        if modifiers.contains(.control) || modifiers.contains(.command) { result += "<Control>" }
        if modifiers.contains(.shift) { result += "<Shift>" }
        if modifiers.contains(.option) { result += "<Alt>" }
        switch key {
        case let .character(character): result += String(character).lowercased()
        case .delete: result += "Delete"
        case .return: result += "Return"
        case .escape: result += "Escape"
        case .upArrow: result += "Up"
        case .downArrow: result += "Down"
        case .leftArrow: result += "Left"
        case .rightArrow: result += "Right"
        }
        return result
    }
}

/// Where Copy to Computer lands when the computer pane is hidden.
enum DefaultDestinations {
    static var downloads: String { XDGUserDirectories().downloads.path }
}
