import CGtk

/// Drag and drop of Swift values between widgets of this app.
///
/// The drag offers only a private MIME type, so other applications ignore
/// it; the payload itself stays in Swift (``InAppDrag/current``) and the drop
/// target reads it back. Use ``FileDragSource``/``FileDropTarget`` for files
/// that should also travel to and from other apps.
@MainActor
public enum InAppDrag {
    /// The payload of the drag in progress, if it started in this app.
    public private(set) static var current: AnyObject?
    fileprivate static func begin(_ payload: AnyObject) { current = payload }
    fileprivate static func end() { current = nil }
}

/// A `GtkDragSource` offering an in-app payload under `mimeType`.
@MainActor
public final class InAppDragSource: EventController {
    public let mimeType: String

    public init(mimeType: String, actions: DragAction = [.copy]) {
        self.mimeType = mimeType
        super.init(rawPtr(gtk_drag_source_new())!)
        gtk_drag_source_set_actions(pointer.cast(), actions.gdk)
    }

    public typealias PrepareFn = @MainActor (_ x: Double, _ y: Double) -> AnyObject?

    /// Return the payload to drag, or nil to refuse the drag.
    public func onPrepare(_ body: @escaping PrepareFn) {
        let mime = mimeType
        let prepare: @MainActor (Double, Double) -> UnsafeMutableRawPointer? = { x, y in
            guard let payload = body(x, y) else { return nil }
            InAppDrag.begin(payload)
            let marker = Array("art-in-app-drag".utf8)
            let bytes = marker.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
            defer { g_bytes_unref(bytes) }
            return rawPtr(gdk_content_provider_new_for_bytes(mime, bytes))
        }
        let callback: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { _, x, y, data in
            let box = Boxed<@MainActor (Double, Double) -> UnsafeMutableRawPointer?>.borrow(data!)
            return onMain { box.value(x, y) }
        }
        connectRaw("prepare", callback: unsafeBitCast(callback, to: UnsafeRawPointer.self), box: Boxed(prepare), swapped: false)
        connect("drag-end") { InAppDrag.end() }
    }
}

/// A `GtkDropTargetAsync` accepting in-app drags of `mimeType`.
@MainActor
public final class InAppDropTarget: EventController {
    public typealias DropFn = @MainActor (_ payload: AnyObject, _ x: Double, _ y: Double) -> Bool
    public typealias HoverFn = @MainActor (Bool) -> Void

    private let handlers = Boxed<(drop: DropFn?, hover: HoverFn?)>((nil, nil))

    public init(mimeType: String) {
        let formats = withCStringArray([mimeType]) { gdk_content_formats_new(UnsafeMutablePointer(mutating: $0), 1) }
        super.init(rawPtr(gtk_drop_target_async_new(formats, GDK_ACTION_COPY))!)

        let enter: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> GdkDragAction = { _, drop, _, _, data in
            // Only drags that started in this app carry a payload we can read.
            guard let drop, gdk_drop_get_drag(drop) != nil else { return GdkDragAction(rawValue: 0) }
            let box = Boxed<(drop: DropFn?, hover: HoverFn?)>.borrow(data!)
            onMain { box.value.hover?(true) }
            return GDK_ACTION_COPY
        }
        let motion: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> GdkDragAction = { _, drop, _, _, _ in
            guard let drop, gdk_drop_get_drag(drop) != nil else { return GdkDragAction(rawValue: 0) }
            return GDK_ACTION_COPY
        }
        let leave: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            let box = Boxed<(drop: DropFn?, hover: HoverFn?)>.borrow(data!)
            onMain { box.value.hover?(false) }
        }
        let drop: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, Double, Double, UnsafeMutableRawPointer?) -> gboolean = { _, drop, x, y, data in
            let box = Boxed<(drop: DropFn?, hover: HoverFn?)>.borrow(data!)
            guard let drop else { return 0 }
            nonisolated(unsafe) let unsafeDrop = drop
            return onMain {
                box.value.hover?(false)
                guard gdk_drop_get_drag(unsafeDrop) != nil, let payload = InAppDrag.current,
                      let handler = box.value.drop else {
                    gdk_drop_finish(unsafeDrop, GdkDragAction(rawValue: 0))
                    return false
                }
                let accepted = handler(payload, x, y)
                gdk_drop_finish(unsafeDrop, accepted ? GDK_ACTION_COPY : GdkDragAction(rawValue: 0))
                return accepted
            }.gbool
        }
        connectRaw("drag-enter", callback: unsafeBitCast(enter, to: UnsafeRawPointer.self), box: handlers, swapped: false)
        connectRaw("drag-motion", callback: unsafeBitCast(motion, to: UnsafeRawPointer.self), box: handlers, swapped: false)
        connectRaw("drag-leave", callback: unsafeBitCast(leave, to: UnsafeRawPointer.self), box: handlers, swapped: false)
        connectRaw("drop", callback: unsafeBitCast(drop, to: UnsafeRawPointer.self), box: handlers, swapped: false)
    }

    /// Return true if the drop was accepted.
    public func onDrop(_ body: @escaping DropFn) { handlers.value.drop = body }

    /// Runs with true while an in-app drag hovers, false when it leaves or drops.
    public func onHoverChanged(_ body: @escaping HoverFn) { handlers.value.hover = body }
}
