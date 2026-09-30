import CGtk

public enum Align: Sendable {
    case fill, start, end, center, baselineFill

    var gtk: GtkAlign {
        switch self {
        case .fill: GTK_ALIGN_FILL
        case .start: GTK_ALIGN_START
        case .end: GTK_ALIGN_END
        case .center: GTK_ALIGN_CENTER
        case .baselineFill: GTK_ALIGN_BASELINE_FILL
        }
    }
}

public enum Orientation: Sendable {
    case horizontal, vertical

    var gtk: GtkOrientation { self == .horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL }
}

/// A `GtkWidget`. Setters return `Self` where chaining reads well:
///
///     Label("Hello").css("title-2").margins(12).align(h: .start)
@MainActor
open class Widget: GObjectRef {
    public var widget: UnsafeMutablePointer<GtkWidget> { pointer.cast() }

    public var isVisible: Bool {
        get { gtk_widget_get_visible(widget).isTrue }
        set { gtk_widget_set_visible(widget, newValue.gbool) }
    }

    public var isSensitive: Bool {
        get { gtk_widget_get_sensitive(widget).isTrue }
        set { gtk_widget_set_sensitive(widget, newValue.gbool) }
    }

    public var isMapped: Bool { gtk_widget_get_mapped(widget).isTrue }

    public var opacity: Double {
        get { gtk_widget_get_opacity(widget) }
        set { gtk_widget_set_opacity(widget, newValue) }
    }

    public var tooltip: String? {
        get { borrowedString(gtk_widget_get_tooltip_text(widget)) }
        set { gtk_widget_set_tooltip_text(widget, newValue) }
    }

    public var hexpand: Bool {
        get { gtk_widget_get_hexpand(widget).isTrue }
        set { gtk_widget_set_hexpand(widget, newValue.gbool) }
    }

    public var vexpand: Bool {
        get { gtk_widget_get_vexpand(widget).isTrue }
        set { gtk_widget_set_vexpand(widget, newValue.gbool) }
    }

    public var name: String? {
        get { borrowedString(gtk_widget_get_name(widget)) }
        set { gtk_widget_set_name(widget, newValue) }
    }

    public var canFocus: Bool {
        get { gtk_widget_get_focusable(widget).isTrue }
        set { gtk_widget_set_focusable(widget, newValue.gbool) }
    }

    public var width: Int { Int(gtk_widget_get_width(widget)) }
    public var height: Int { Int(gtk_widget_get_height(widget)) }

    @discardableResult
    public func expand(h: Bool? = nil, v: Bool? = nil) -> Self {
        if let h { hexpand = h }
        if let v { vexpand = v }
        return self
    }

    @discardableResult
    public func align(h: Align? = nil, v: Align? = nil) -> Self {
        if let h { gtk_widget_set_halign(widget, h.gtk) }
        if let v { gtk_widget_set_valign(widget, v.gtk) }
        return self
    }

    @discardableResult
    public func margins(_ all: Int32) -> Self { margins(top: all, bottom: all, start: all, end: all) }

    @discardableResult
    public func margins(top: Int32? = nil, bottom: Int32? = nil, start: Int32? = nil, end: Int32? = nil) -> Self {
        if let top { gtk_widget_set_margin_top(widget, top) }
        if let bottom { gtk_widget_set_margin_bottom(widget, bottom) }
        if let start { gtk_widget_set_margin_start(widget, start) }
        if let end { gtk_widget_set_margin_end(widget, end) }
        return self
    }

    @discardableResult
    public func sizeRequest(width: Int32 = -1, height: Int32 = -1) -> Self {
        gtk_widget_set_size_request(widget, width, height)
        return self
    }

    /// Adds style classes (`"title-1"`, `"dim-label"`, `"suggested-action"`…).
    @discardableResult
    public func css(_ classes: String...) -> Self {
        classes.forEach { gtk_widget_add_css_class(widget, $0) }
        return self
    }

    public func addCSSClass(_ name: String) { gtk_widget_add_css_class(widget, name) }
    public func removeCSSClass(_ name: String) { gtk_widget_remove_css_class(widget, name) }
    public func hasCSSClass(_ name: String) -> Bool { gtk_widget_has_css_class(widget, name).isTrue }
    public func setCSSClass(_ name: String, _ on: Bool) { on ? addCSSClass(name) : removeCSSClass(name) }

    @discardableResult
    public func grabFocus() -> Bool { gtk_widget_grab_focus(widget).isTrue }

    public func add(_ controller: EventController) {
        gtk_widget_add_controller(widget, controller.pointer.cast())
        g_object_ref(controller.pointer) // add_controller takes ownership
    }

    public func insertActionGroup(_ group: ActionGroup, prefix: String) {
        gtk_widget_insert_action_group(widget, prefix, group.pointer.cast())
    }

    /// Activates an action by detailed name from this widget's scope
    /// (`win.copy`, `pane.refresh`, `app.quit`).
    @discardableResult
    public func activateAction(_ name: String) -> Bool {
        gtk_widget_activate_action_variant(widget, name, nil).isTrue
    }

    public func queueDraw() { gtk_widget_queue_draw(widget) }

    /// Removes the widget from its parent (a GtkBox, or any widget that
    /// parented it directly).
    public func unparentFromContainer() {
        guard let parent = gtk_widget_get_parent(widget) else { return }
        let instance = UnsafeMutableRawPointer(parent).assumingMemoryBound(to: GTypeInstance.self)
        if g_type_check_instance_is_a(instance, gtk_box_get_type()).isTrue {
            gtk_box_remove(UnsafeMutableRawPointer(parent).cast(), widget)
        } else {
            gtk_widget_unparent(widget)
        }
    }

    /// The window containing this widget, if it is in one.
    public var rootWindowPointer: UnsafeMutableRawPointer? {
        guard let root = gtk_widget_get_root(widget) else { return nil }
        return UnsafeMutableRawPointer(root)
    }

    public func onMap(_ body: @escaping @MainActor () -> Void) { connect("map", body) }
    public func onUnmap(_ body: @escaping @MainActor () -> Void) { connect("unmap", body) }
    /// Runs when the widget is disposed (the GTK "destroy" signal).
    public func onDestroy(_ body: @escaping @MainActor () -> Void) { connect("destroy", body) }
}

/// The wrapper of a widget pointer GTK lends (transfer none): the existing
/// Swift wrapper if there is one, else a new generic one.
@MainActor
public func borrowWidget(_ pointer: UnsafeMutableRawPointer) -> Widget {
    (GObjectRef.wrapper(for: pointer) as? Widget) ?? Widget(pointer, .retain)
}

// MARK: - Event controllers

/// A `GtkEventController`; attach with ``Widget/add(_:)``.
@MainActor
open class EventController: GObjectRef {
    public var controllerWidgetPointer: UnsafeMutableRawPointer? {
        rawPtr(gtk_event_controller_get_widget(pointer.cast()))
    }

    public enum Phase: Sendable { case capture, bubble, target }

    public var phase: Phase {
        get {
            switch gtk_event_controller_get_propagation_phase(pointer.cast()) {
            case GTK_PHASE_CAPTURE: .capture
            case GTK_PHASE_TARGET: .target
            default: .bubble
            }
        }
        set {
            let value: GtkPropagationPhase = switch newValue {
            case .capture: GTK_PHASE_CAPTURE
            case .bubble: GTK_PHASE_BUBBLE
            case .target: GTK_PHASE_TARGET
            }
            gtk_event_controller_set_propagation_phase(pointer.cast(), value)
        }
    }
}

/// A `GtkGestureClick`: clicks with press count (double-click = 2).
@MainActor
public final class ClickGesture: EventController {
    public init(button: UInt32 = 0) {
        super.init(rawPtr(gtk_gesture_click_new())!)
        gtk_gesture_single_set_button(pointer.cast(), button)
    }

    public typealias PressedFn = @MainActor (_ count: Int, _ x: Double, _ y: Double) -> Void

    public func onPressed(_ body: @escaping PressedFn) {
        let callback: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, n, x, y, data in
            let box = Boxed<PressedFn>.borrow(data!)
            onMain { box.value(Int(n), x, y) }
        }
        connectRaw("pressed", callback: unsafeBitCast(callback, to: UnsafeRawPointer.self), box: Boxed(body), swapped: false)
    }

    /// The mouse button of the current press (1 primary, 3 secondary).
    public var currentButton: UInt32 { gtk_gesture_single_get_current_button(pointer.cast()) }
}

/// A `GtkEventControllerKey`/`Motion`/`Scroll` pair collapsed into "the user
/// did something" (used by idle detection).
@MainActor
public final class ActivityController: EventController {
    public enum Kind: Sendable { case key, motion, scroll }

    public init(_ kind: Kind) {
        switch kind {
        case .key: super.init(rawPtr(gtk_event_controller_key_new())!)
        case .motion: super.init(rawPtr(gtk_event_controller_motion_new())!)
        case .scroll: super.init(rawPtr(gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES))!)
        }
        phase = .capture
    }

    /// `handler` runs on every key press, pointer motion or scroll.
    public func onActivity(_ handler: @escaping @MainActor () -> Void) {
        for signal in ["key-pressed", "motion", "scroll"] where g_signal_lookup(signal, G_TYPE_FROM_INSTANCE_PTR(pointer)) != 0 {
            if signal == "key-pressed" || signal == "scroll" {
                // Both return gboolean: false = let the event propagate.
                connectBool(signal) { handler(); return false }
            } else {
                connect(signal, handler)
            }
        }
    }
}

@inline(__always)
func G_TYPE_FROM_INSTANCE_PTR(_ p: UnsafeMutableRawPointer) -> GType {
    p.assumingMemoryBound(to: GTypeInstance.self).pointee.g_class.pointee.g_type
}
