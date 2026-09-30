import CGtk

// Desktop integration: appearance, clipboard, opening files and links,
// file-type icons and GIO mounts.

/// The libadwaita style manager (light/dark appearance).
@MainActor
public enum StyleManager {
    public enum ColorScheme: Sendable { case system, light, dark }

    private static var manager: OpaquePointer { adw_style_manager_get_default() }

    public static var colorScheme: ColorScheme {
        get {
            switch adw_style_manager_get_color_scheme(manager) {
            case ADW_COLOR_SCHEME_FORCE_LIGHT: .light
            case ADW_COLOR_SCHEME_FORCE_DARK: .dark
            default: .system
            }
        }
        set {
            let scheme: AdwColorScheme = switch newValue {
            case .system: ADW_COLOR_SCHEME_DEFAULT
            case .light: ADW_COLOR_SCHEME_FORCE_LIGHT
            case .dark: ADW_COLOR_SCHEME_FORCE_DARK
            }
            adw_style_manager_set_color_scheme(manager, scheme)
        }
    }

    /// Whether the app currently renders dark.
    public static var isDark: Bool { adw_style_manager_get_dark(manager).isTrue }
}

/// The icon theme of the default display.
@MainActor
public enum IconTheme {
    /// Whether the theme (or the hicolor fallback) has an icon called `name`.
    public static func has(_ name: String) -> Bool {
        guard let display = gdk_display_get_default(), let theme = gtk_icon_theme_get_for_display(display) else { return false }
        return gtk_icon_theme_has_icon(theme, name).isTrue
    }
}

/// The default display's clipboard.
@MainActor
public enum Clipboard {
    public static func setText(_ text: String) {
        guard let display = gdk_display_get_default() else { return }
        gdk_clipboard_set_text(gdk_display_get_clipboard(display), text)
    }
}

/// Opens files, folders and links with the desktop's default handlers
/// (through the portal when sandboxed).
@MainActor
public enum Launcher {
    /// Opens `path` with its default application.
    public static func open(path: String, parent: Window? = nil, completion: (@MainActor (GLibError?) -> Void)? = nil) {
        let file = g_file_new_for_path(path)
        let launcher = gtk_file_launcher_new(file)
        g_object_unref(UnsafeMutableRawPointer(file))
        let done: AsyncDone = { source, result in
            var error: UnsafeMutablePointer<GError>?
            if let source { _ = gtk_file_launcher_launch_finish(source.cast(), result, &error) }
            completion?(error.map(GLibError.init(taking:)))
            if let source { g_object_unref(source) }
        }
        gtk_file_launcher_launch(launcher, parent?.pointer.cast(), nil, asyncReadyTrampoline, Boxed(done).retainedPointer())
    }

    /// Shows `path` selected in the file manager.
    public static func showInFileManager(path: String, parent: Window? = nil, completion: (@MainActor (GLibError?) -> Void)? = nil) {
        let file = g_file_new_for_path(path)
        let launcher = gtk_file_launcher_new(file)
        g_object_unref(UnsafeMutableRawPointer(file))
        let done: AsyncDone = { source, result in
            var error: UnsafeMutablePointer<GError>?
            if let source { _ = gtk_file_launcher_open_containing_folder_finish(source.cast(), result, &error) }
            completion?(error.map(GLibError.init(taking:)))
            if let source { g_object_unref(source) }
        }
        gtk_file_launcher_open_containing_folder(launcher, parent?.pointer.cast(), nil, asyncReadyTrampoline, Boxed(done).retainedPointer())
    }

    /// Opens a web link in the browser.
    public static func open(uri: String, parent: Window? = nil) {
        let launcher = gtk_uri_launcher_new(uri)
        let done: AsyncDone = { source, result in
            if let source {
                _ = gtk_uri_launcher_launch_finish(source.cast(), result, nil)
                g_object_unref(source)
            }
        }
        gtk_uri_launcher_launch(launcher, parent?.pointer.cast(), nil, asyncReadyTrampoline, Boxed(done).retainedPointer())
    }
}

/// shared-mime-info content types for file names.
public enum ContentType {
    /// The content type guessed from a file name alone (no I/O), e.g. `image/jpeg`.
    public static func guess(fileName: String) -> String {
        var uncertain: gboolean = 0
        return takenString(g_content_type_guess(fileName, nil, 0, &uncertain)) ?? "application/octet-stream"
    }

    /// A human description, e.g. "JPEG image".
    public static func description(of type: String) -> String {
        takenString(g_content_type_get_description(type)) ?? type
    }

    /// Themed icon names for the type, most specific first.
    public static func iconNames(of type: String, symbolic: Bool = false) -> [String] {
        guard let icon = symbolic ? g_content_type_get_symbolic_icon(type) : g_content_type_get_icon(type) else { return [] }
        defer { g_object_unref(UnsafeMutableRawPointer(icon)) }
        guard let names = g_themed_icon_get_names(UnsafeMutableRawPointer(icon).cast()) else { return [] }
        var result: [String] = []
        var index = 0
        while let name = names[index] {
            result.append(String(cString: name))
            index += 1
        }
        return result
    }
}

/// GIO mounts (what file managers show in their sidebars). Creating the
/// volume monitor starts the desktop's volume-monitor services, so call these
/// only in response to the user.
@MainActor
public enum GioMounts {
    /// Root URIs of the current mounts, e.g. `mtp://Google_Pixel_8_ABC/`.
    public static func rootURIs() -> [String] {
        guard let monitor = g_volume_monitor_get() else { return [] }
        defer { g_object_unref(UnsafeMutableRawPointer(monitor)) }
        let list = g_volume_monitor_get_mounts(monitor)
        defer { g_list_free_full(list, { g_object_unref($0) }) }
        var result: [String] = []
        var node = list
        while let current = node {
            if let mount = current.pointee.data, let root = g_mount_get_root(OpaquePointer(mount)) {
                if let uri = takenString(g_file_get_uri(root)) { result.append(uri) }
                g_object_unref(UnsafeMutableRawPointer(root))
            }
            node = current.pointee.next
        }
        return result
    }

    /// Unmounts every mount whose root URI starts with `prefix` (like
    /// `gio mount -u`). `completion` gets the error messages, empty on success.
    public static func unmount(rootURIPrefix prefix: String, completion: @escaping @MainActor ([String]) -> Void) {
        guard let monitor = g_volume_monitor_get() else { completion(["No volume monitor"]); return }
        let list = g_volume_monitor_get_mounts(monitor)
        g_object_unref(UnsafeMutableRawPointer(monitor))
        var mounts: [OpaquePointer] = []
        var node = list
        while let current = node {
            if let mount = current.pointee.data {
                let root = g_mount_get_root(OpaquePointer(mount))
                let uri = root.flatMap { takenString(g_file_get_uri($0)) } ?? ""
                if let root { g_object_unref(UnsafeMutableRawPointer(root)) }
                if uri.hasPrefix(prefix) {
                    g_object_ref(mount)
                    mounts.append(OpaquePointer(mount))
                }
            }
            node = current.pointee.next
        }
        g_list_free_full(list, { g_object_unref($0) })
        guard !mounts.isEmpty else { completion([]); return }

        var remaining = mounts.count
        var errors: [String] = []
        for mount in mounts {
            let done: AsyncDone = { source, result in
                var error: UnsafeMutablePointer<GError>?
                if let source { _ = g_mount_unmount_with_operation_finish(source.cast(), result, &error) }
                if let error { errors.append(GLibError(taking: error).message) }
                if let source { g_object_unref(source) }
                remaining -= 1
                if remaining == 0 { completion(errors) }
            }
            g_mount_unmount_with_operation(mount, GMountUnmountFlags(rawValue: 0), nil, nil, asyncReadyTrampoline, Boxed(done).retainedPointer())
        }
    }
}
