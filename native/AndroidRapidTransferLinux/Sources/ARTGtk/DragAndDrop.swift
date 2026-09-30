import CGtk

/// `GdkDragAction` as a Swift option set.
public struct DragAction: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let copy = DragAction(rawValue: GDK_ACTION_COPY.rawValue)
    public static let move = DragAction(rawValue: GDK_ACTION_MOVE.rawValue)
    public static let link = DragAction(rawValue: GDK_ACTION_LINK.rawValue)

    var gdk: GdkDragAction { GdkDragAction(rawValue: rawValue) }
}

/// Parses a `text/uri-list` payload (RFC 2483) into local paths; non-file
/// URIs are kept as URIs. Pure function, unit-tested.
public func parseURIList(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline) // "\r\n" is one Character
        .map(trimSpaces)
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .map { uri in
            guard uri.hasPrefix("file://") else { return uri }
            return takenString(g_filename_from_uri(uri, nil, nil)) ?? uri
        }
}

private func trimSpaces(_ s: Substring) -> String {
    var s = s
    while let first = s.first, first == " " || first == "\t" { s.removeFirst() }
    while let last = s.last, last == " " || last == "\t" { s.removeLast() }
    return String(s)
}

/// Paths (or URIs) from a GValue holding a `GdkFileList` or a URI-list string.
func paths(from value: UnsafePointer<GValue>) -> [String] {
    if art_value_holds(value, art_type_file_list()).isTrue {
        guard let list = g_value_get_boxed(value) else { return [] }
        let files = gdk_file_list_get_files(OpaquePointer(list))
        defer { g_slist_free(files) }
        var result: [String] = []
        var node = files
        while let current = node {
            if let file = current.pointee.data {
                let path = takenString(g_file_get_path(OpaquePointer(file))) ?? takenString(g_file_get_uri(OpaquePointer(file)))
                if let path { result.append(path) }
            }
            node = current.pointee.next
        }
        return result
    }
    if art_value_holds(value, art_type_string()).isTrue, let text = g_value_get_string(value) {
        return parseURIList(String(cString: text))
    }
    return []
}

/// A `GtkDropTarget` for files dragged in from a file manager.
///
/// Accepts COPY and MOVE (Nautilus offers MOVE by default) and both
/// `GdkFileList` (which GTK fills from `text/uri-list` and the portal file
/// formats) and plain URI-list strings as a fallback.
///
///     let drop = FileDropTarget()
///     drop.onDrop { paths, _, _ in model.upload(paths); return true }
///     pane.add(drop)
@MainActor
public final class FileDropTarget: EventController {
    public init(actions: DragAction = [.copy, .move]) {
        super.init(rawPtr(gtk_drop_target_new(GType(0), actions.gdk))!)
        var types: [GType] = [art_type_file_list(), art_type_string()]
        gtk_drop_target_set_gtypes(pointer.cast(), &types, gsize(types.count))
    }

    public typealias DropFn = @MainActor (_ paths: [String], _ x: Double, _ y: Double) -> Bool

    /// Return true if the drop was accepted.
    public func onDrop(_ body: @escaping DropFn) {
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<GValue>?, Double, Double, UnsafeMutableRawPointer?) -> gboolean = { _, value, x, y, data in
            let box = Boxed<DropFn>.borrow(data!)
            guard let value else { return 0 }
            let dropped = paths(from: value)
            return onMain { box.value(dropped, x, y) }.gbool
        }
        connectRaw("drop", callback: unsafeBitCast(callback, to: UnsafeRawPointer.self), box: Boxed(body), swapped: false)
    }

    /// Runs with true while a drag hovers over the widget, false when it leaves
    /// or drops (for highlight styling; GTK also sets the `:drop(active)` state).
    public func onHoverChanged(_ body: @escaping @MainActor (Bool) -> Void) {
        let weak = WeakObject(pointer)
        onNotify("current-drop") {
            let hovering = weak.withObject { gtk_drop_target_get_current_drop($0.cast()) != nil } ?? false
            body(hovering)
        }
    }
}

/// A `GtkDragSource` offering local files (as a `GdkFileList`, which GTK also
/// serialises to `text/uri-list` for other apps).
///
///     let drag = FileDragSource()
///     drag.onPrepare { _, _ in selection.map(\.path) }
///     table.add(drag)
@MainActor
public final class FileDragSource: EventController {
    public init(actions: DragAction = [.copy]) {
        super.init(rawPtr(gtk_drag_source_new())!)
        gtk_drag_source_set_actions(pointer.cast(), actions.gdk)
    }

    public typealias PrepareFn = @MainActor (_ x: Double, _ y: Double) -> [String]?

    /// Return the paths to drag, or nil/empty to refuse the drag.
    public func onPrepare(_ body: @escaping PrepareFn) {
        let callback: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { _, x, y, data in
            let box = Boxed<PrepareFn>.borrow(data!)
            guard let paths = onMain({ box.value(x, y) }), !paths.isEmpty else { return nil }
            var files: [OpaquePointer?] = paths.map { g_file_new_for_path($0) }
            defer { files.forEach { g_object_unref(UnsafeMutableRawPointer($0)) } }
            return files.withUnsafeMutableBufferPointer { buffer in
                rawPtr(art_content_provider_for_files(buffer.baseAddress, gsize(buffer.count)))
            }
        }
        connectRaw("prepare", callback: unsafeBitCast(callback, to: UnsafeRawPointer.self), box: Boxed(body), swapped: false)
    }

    /// Runs when the drag finishes; `deleteData` is true for a completed MOVE.
    public func onDragEnd(_ body: @escaping @MainActor (_ deleteData: Bool) -> Void) {
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, gboolean, UnsafeMutableRawPointer?) -> Void = { _, _, delete, data in
            let box = Boxed<@MainActor (Bool) -> Void>.borrow(data!)
            onMain { box.value(delete.isTrue) }
        }
        connectRaw("drag-end", callback: unsafeBitCast(callback, to: UnsafeRawPointer.self), box: Boxed(body), swapped: false)
    }
}

// MARK: - CSS

/// Application-wide CSS.
///
///     CSS.load(".drop-highlight { background: alpha(@accent_bg_color, .15); transition: background 150ms; }")
///
/// CSS transitions honour the global animation switch (`gtk-enable-animations`).
@MainActor
public enum CSS {
    @discardableResult
    public static func load(_ css: String, priority: UInt32 = UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)) -> GObjectRef {
        let provider = GObjectRef(rawPtr(gtk_css_provider_new())!)
        gtk_css_provider_load_from_string(provider.pointer.cast(), css)
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(display, provider.pointer.cast(), priority)
        }
        return provider
    }

    public static func unload(_ provider: GObjectRef) {
        if let display = gdk_display_get_default() {
            gtk_style_context_remove_provider_for_display(display, provider.pointer.cast())
        }
    }
}
