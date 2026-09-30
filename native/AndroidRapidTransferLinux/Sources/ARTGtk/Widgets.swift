import CGtk

// MARK: - Windows

/// A `GtkWindow`. GTK owns top-level windows; the wrapper holds an extra
/// reference until it is released, and ``destroy()`` closes the window.
@MainActor
open class Window: Widget {
    /// Wraps an existing window pointer.
    public init(windowPointer: UnsafeMutableRawPointer) {
        super.init(windowPointer, .retain)
    }

    /// A plain `GtkWindow` (secondary windows, tests).
    public convenience init() {
        self.init(windowPointer: rawPtr(gtk_window_new())!)
    }

    public var window: OpaquePointer { pointer.cast() }

    public var title: String? {
        get { borrowedString(gtk_window_get_title(pointer.cast())) }
        set { gtk_window_set_title(pointer.cast(), newValue) }
    }

    public func setDefaultSize(width: Int32, height: Int32) {
        gtk_window_set_default_size(pointer.cast(), width, height)
    }

    /// For a plain GtkWindow; `ApplicationWindow` uses ``ApplicationWindow/content``.
    public func setChild(_ child: Widget?) { gtk_window_set_child(pointer.cast(), child?.widget) }

    public func present() { gtk_window_present(pointer.cast()) }
    public func close() { gtk_window_close(pointer.cast()) }
    public func destroy() { gtk_window_destroy(pointer.cast()) }

    /// Whether the window has keyboard focus (the "active" window).
    public var isActive: Bool { gtk_window_is_active(pointer.cast()).isTrue }
    /// Whether the compositor reports the window as not visible (minimized,
    /// on another workspace…).
    public var isSuspended: Bool { gtk_window_is_suspended(pointer.cast()).isTrue }

    /// Return true to keep the window open.
    public func onCloseRequest(_ body: @escaping @MainActor () -> Bool) { connectBool("close-request", body) }
}

/// An `AdwApplicationWindow`: also an action map for `win.` actions.
@MainActor
public final class ApplicationWindow: Window, ActionMap {
    public init(application: Application) {
        let p = rawPtr(adw_application_window_new(application.pointer.cast()))!
        super.init(windowPointer: p)
    }

    public var content: Widget? {
        didSet { adw_application_window_set_content(pointer.cast(), content?.widget) }
    }
}

// MARK: - Structure

/// An `AdwToolbarView`: top bars, content, bottom bars.
@MainActor
public final class ToolbarView: Widget {
    public init() { super.init(rawPtr(adw_toolbar_view_new())!) }

    public func addTopBar(_ bar: Widget) { adw_toolbar_view_add_top_bar(pointer.cast(), bar.widget) }
    public func addBottomBar(_ bar: Widget) { adw_toolbar_view_add_bottom_bar(pointer.cast(), bar.widget) }

    public var content: Widget? {
        didSet { adw_toolbar_view_set_content(pointer.cast(), content?.widget) }
    }

    public var revealsBottomBars: Bool {
        get { adw_toolbar_view_get_reveal_bottom_bars(pointer.cast()).isTrue }
        set { adw_toolbar_view_set_reveal_bottom_bars(pointer.cast(), newValue.gbool) }
    }
}

/// An `AdwHeaderBar`.
@MainActor
public final class HeaderBar: Widget {
    public init() { super.init(rawPtr(adw_header_bar_new())!) }

    public func packStart(_ child: Widget) { adw_header_bar_pack_start(pointer.cast(), child.widget) }
    public func packEnd(_ child: Widget) { adw_header_bar_pack_end(pointer.cast(), child.widget) }

    public var titleWidget: Widget? {
        didSet { adw_header_bar_set_title_widget(pointer.cast(), titleWidget?.widget) }
    }
}

/// An `AdwWindowTitle` (title + subtitle for a header bar).
@MainActor
public final class WindowTitle: Widget {
    public init(title: String, subtitle: String = "") {
        super.init(rawPtr(adw_window_title_new(title, subtitle))!)
    }

    public var title: String {
        get { borrowedString(adw_window_title_get_title(pointer.cast())) ?? "" }
        set { adw_window_title_set_title(pointer.cast(), newValue) }
    }

    public var subtitle: String {
        get { borrowedString(adw_window_title_get_subtitle(pointer.cast())) ?? "" }
        set { adw_window_title_set_subtitle(pointer.cast(), newValue) }
    }
}

/// A `GtkBox`.
@MainActor
public final class Box: Widget {
    public init(_ orientation: Orientation = .vertical, spacing: Int32 = 0, _ children: [Widget] = []) {
        super.init(rawPtr(gtk_box_new(orientation.gtk, spacing))!)
        children.forEach(append)
    }

    public func append(_ child: Widget) { gtk_box_append(pointer.cast(), child.widget) }
    public func prepend(_ child: Widget) { gtk_box_prepend(pointer.cast(), child.widget) }
    public func remove(_ child: Widget) { gtk_box_remove(pointer.cast(), child.widget) }

    public var isHomogeneous: Bool {
        get { gtk_box_get_homogeneous(pointer.cast()).isTrue }
        set { gtk_box_set_homogeneous(pointer.cast(), newValue.gbool) }
    }
}

/// A `GtkPaned` (the dual-pane split).
@MainActor
public final class Paned: Widget {
    public init(_ orientation: Orientation = .horizontal, start: Widget? = nil, end: Widget? = nil) {
        super.init(rawPtr(gtk_paned_new(orientation.gtk))!)
        // (didSet does not run for assignments in the class's own init)
        self.start = start
        self.end = end
        gtk_paned_set_start_child(pointer.cast(), start?.widget)
        gtk_paned_set_end_child(pointer.cast(), end?.widget)
    }

    public var start: Widget? {
        didSet { gtk_paned_set_start_child(pointer.cast(), start?.widget) }
    }

    public var end: Widget? {
        didSet { gtk_paned_set_end_child(pointer.cast(), end?.widget) }
    }

    public var position: Int32 {
        get { gtk_paned_get_position(pointer.cast()) }
        set { gtk_paned_set_position(pointer.cast(), newValue) }
    }

    public var hasWideHandle: Bool {
        get { gtk_paned_get_wide_handle(pointer.cast()).isTrue }
        set { gtk_paned_set_wide_handle(pointer.cast(), newValue.gbool) }
    }

    /// Whether each side may shrink below its minimum size / grows on resize.
    public func configure(resizeStart: Bool = true, resizeEnd: Bool = true, shrinkStart: Bool = false, shrinkEnd: Bool = false) {
        gtk_paned_set_resize_start_child(pointer.cast(), resizeStart.gbool)
        gtk_paned_set_resize_end_child(pointer.cast(), resizeEnd.gbool)
        gtk_paned_set_shrink_start_child(pointer.cast(), shrinkStart.gbool)
        gtk_paned_set_shrink_end_child(pointer.cast(), shrinkEnd.gbool)
    }
}

/// A `GtkScrolledWindow`.
@MainActor
public final class ScrolledWindow: Widget {
    public enum Policy: Sendable {
        case automatic, always, never, external
        var gtk: GtkPolicyType {
            switch self {
            case .automatic: GTK_POLICY_AUTOMATIC
            case .always: GTK_POLICY_ALWAYS
            case .never: GTK_POLICY_NEVER
            case .external: GTK_POLICY_EXTERNAL
            }
        }
    }

    public init(_ child: Widget? = nil) {
        super.init(rawPtr(gtk_scrolled_window_new())!)
        self.child = child
        gtk_scrolled_window_set_child(pointer.cast(), child?.widget)
    }

    public var child: Widget? {
        didSet { gtk_scrolled_window_set_child(pointer.cast(), child?.widget) }
    }

    public func setPolicy(h: Policy, v: Policy) {
        gtk_scrolled_window_set_policy(pointer.cast(), h.gtk, v.gtk)
    }

    public var propagatesNaturalHeight: Bool {
        get { gtk_scrolled_window_get_propagate_natural_height(pointer.cast()).isTrue }
        set { gtk_scrolled_window_set_propagate_natural_height(pointer.cast(), newValue.gbool) }
    }
}

/// A `GtkOverlay`.
@MainActor
public final class Overlay: Widget {
    public init(_ child: Widget? = nil) {
        super.init(rawPtr(gtk_overlay_new())!)
        self.child = child
        gtk_overlay_set_child(pointer.cast(), child?.widget)
    }

    public var child: Widget? {
        didSet { gtk_overlay_set_child(pointer.cast(), child?.widget) }
    }

    public func addOverlay(_ overlay: Widget) { gtk_overlay_add_overlay(pointer.cast(), overlay.widget) }
}

/// A `GtkSeparator`.
@MainActor
public final class Separator: Widget {
    public init(_ orientation: Orientation = .horizontal) {
        super.init(rawPtr(gtk_separator_new(orientation.gtk))!)
    }
}

/// A `GtkRevealer`: slides or fades a child in and out (honours the global
/// animation switch).
@MainActor
public final class Revealer: Widget {
    public enum Transition: Sendable {
        case none, crossfade, slideUp, slideDown, slideLeft, slideRight
        var gtk: GtkRevealerTransitionType {
            switch self {
            case .none: GTK_REVEALER_TRANSITION_TYPE_NONE
            case .crossfade: GTK_REVEALER_TRANSITION_TYPE_CROSSFADE
            case .slideUp: GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP
            case .slideDown: GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN
            case .slideLeft: GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT
            case .slideRight: GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT
            }
        }
    }

    public init(_ child: Widget? = nil, transition: Transition = .slideUp, duration: Double = Motion.Duration.standard) {
        super.init(rawPtr(gtk_revealer_new())!)
        self.child = child
        gtk_revealer_set_child(pointer.cast(), child?.widget)
        gtk_revealer_set_transition_type(pointer.cast(), transition.gtk)
        gtk_revealer_set_transition_duration(pointer.cast(), UInt32(duration * 1000))
    }

    public var child: Widget? {
        didSet { gtk_revealer_set_child(pointer.cast(), child?.widget) }
    }

    public var isRevealed: Bool {
        get { gtk_revealer_get_reveal_child(pointer.cast()).isTrue }
        set { gtk_revealer_set_reveal_child(pointer.cast(), newValue.gbool) }
    }
}

// MARK: - Stacks

/// A `GtkStack`.
@MainActor
public final class Stack: Widget {
    public enum Transition: Sendable {
        case none, crossfade, slideLeftRight, slideUpDown
        var gtk: GtkStackTransitionType {
            switch self {
            case .none: GTK_STACK_TRANSITION_TYPE_NONE
            case .crossfade: GTK_STACK_TRANSITION_TYPE_CROSSFADE
            case .slideLeftRight: GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT
            case .slideUpDown: GTK_STACK_TRANSITION_TYPE_SLIDE_UP_DOWN
            }
        }
    }

    public init(transition: Transition = .crossfade, duration: Double = Motion.Duration.standard) {
        super.init(rawPtr(gtk_stack_new())!)
        gtk_stack_set_transition_type(pointer.cast(), transition.gtk)
        gtk_stack_set_transition_duration(pointer.cast(), UInt32(duration * 1000))
    }

    public func add(_ child: Widget, name: String, title: String? = nil) {
        if let title {
            gtk_stack_add_titled(pointer.cast(), child.widget, name, title)
        } else {
            gtk_stack_add_named(pointer.cast(), child.widget, name)
        }
    }

    public var visibleChildName: String? {
        get { borrowedString(gtk_stack_get_visible_child_name(pointer.cast())) }
        set { if let newValue { gtk_stack_set_visible_child_name(pointer.cast(), newValue) } }
    }
}

/// An `AdwViewStack` with pages for an `AdwViewSwitcher`.
@MainActor
public final class ViewStack: Widget {
    public init() { super.init(rawPtr(adw_view_stack_new())!) }

    public func add(_ child: Widget, name: String, title: String, iconName: String? = nil) {
        adw_view_stack_add_titled_with_icon(pointer.cast(), child.widget, name, title, iconName)
    }

    public var visibleChildName: String? {
        get { borrowedString(adw_view_stack_get_visible_child_name(pointer.cast())) }
        set { if let newValue { adw_view_stack_set_visible_child_name(pointer.cast(), newValue) } }
    }

    public func onVisibleChildChanged(_ body: @escaping @MainActor () -> Void) { onNotify("visible-child", body) }
}

/// An `AdwViewSwitcher` for a ``ViewStack``.
@MainActor
public final class ViewSwitcher: Widget {
    public init(stack: ViewStack, wide: Bool = true) {
        super.init(rawPtr(adw_view_switcher_new())!)
        adw_view_switcher_set_stack(pointer.cast(), stack.pointer.cast())
        adw_view_switcher_set_policy(pointer.cast(), wide ? ADW_VIEW_SWITCHER_POLICY_WIDE : ADW_VIEW_SWITCHER_POLICY_NARROW)
    }
}

// MARK: - Controls

/// A `GtkButton` with a label, an icon, or both (via `AdwButtonContent`).
@MainActor
public final class Button: Widget {
    public init(_ label: String) {
        super.init(rawPtr(gtk_button_new_with_label(label))!)
    }

    public init(iconName: String, tooltip: String? = nil) {
        super.init(rawPtr(gtk_button_new_from_icon_name(iconName))!)
        self.tooltip = tooltip
    }

    public init(_ label: String, iconName: String) {
        super.init(rawPtr(gtk_button_new())!)
        let content = adw_button_content_new()!
        adw_button_content_set_label(UnsafeMutableRawPointer(content).cast(), label)
        adw_button_content_set_icon_name(UnsafeMutableRawPointer(content).cast(), iconName)
        gtk_button_set_child(pointer.cast(), content)
    }

    public var label: String? {
        get { borrowedString(gtk_button_get_label(pointer.cast())) }
        set { gtk_button_set_label(pointer.cast(), newValue) }
    }

    public var iconName: String? {
        get { borrowedString(gtk_button_get_icon_name(pointer.cast())) }
        set { if let newValue { gtk_button_set_icon_name(pointer.cast(), newValue) } }
    }

    /// Runs `body` when the button is clicked (the sender is not captured).
    public func onClicked(_ body: @escaping @MainActor () -> Void) { connect("clicked", body) }

    /// Makes the button trigger an action (`win.copy`) instead of a closure.
    public var actionName: String? {
        get { borrowedString(gtk_actionable_get_action_name(pointer.cast())) }
        set { gtk_actionable_set_action_name(pointer.cast(), newValue) }
    }
}

/// A `GtkMenuButton` showing a ``Menu`` in a popover.
@MainActor
public final class MenuButton: Widget {
    public init(iconName: String = "open-menu-symbolic", menu: Menu, primary: Bool = false) {
        super.init(rawPtr(gtk_menu_button_new())!)
        gtk_menu_button_set_icon_name(pointer.cast(), iconName)
        gtk_menu_button_set_menu_model(pointer.cast(), menu.pointer.cast())
        gtk_menu_button_set_primary(pointer.cast(), primary.gbool)
    }

    public func popup() { gtk_menu_button_popup(pointer.cast()) }
    public func popdown() { gtk_menu_button_popdown(pointer.cast()) }
}

/// A `GtkPopoverMenu` for context menus: attach to a widget, then
/// ``popup(at:y:)`` from a secondary-click gesture.
@MainActor
public final class PopoverMenu: Widget {
    public init(menu: Menu, parent: Widget) {
        super.init(rawPtr(gtk_popover_menu_new_from_model(menu.pointer.cast()))!)
        gtk_widget_set_parent(widget, parent.widget)
        gtk_popover_set_has_arrow(pointer.cast(), 0)
        let weak = WeakObject(pointer)
        // A popover parented by hand must be unparented before its parent goes.
        parent.onDestroy { weak.withObject { gtk_widget_unparent($0.cast()) } }
    }

    public func popup(at x: Double, y: Double) {
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(pointer.cast(), &rect)
        gtk_popover_popup(pointer.cast())
    }

    public func popdown() { gtk_popover_popdown(pointer.cast()) }
}

/// A `GtkLabel`.
@MainActor
public final class Label: Widget {
    public init(_ text: String = "") {
        super.init(rawPtr(gtk_label_new(text))!)
    }

    public var text: String {
        get { borrowedString(gtk_label_get_text(pointer.cast())) ?? "" }
        set { gtk_label_set_text(pointer.cast(), newValue) }
    }

    public func setMarkup(_ markup: String) { gtk_label_set_markup(pointer.cast(), markup) }

    public var xalign: Float {
        get { gtk_label_get_xalign(pointer.cast()) }
        set { gtk_label_set_xalign(pointer.cast(), newValue) }
    }

    public enum Ellipsis: Sendable { case none, start, middle, end }

    public var ellipsis: Ellipsis = .none {
        didSet {
            let mode: PangoEllipsizeMode = switch ellipsis {
            case .none: PANGO_ELLIPSIZE_NONE
            case .start: PANGO_ELLIPSIZE_START
            case .middle: PANGO_ELLIPSIZE_MIDDLE
            case .end: PANGO_ELLIPSIZE_END
            }
            gtk_label_set_ellipsize(pointer.cast(), mode)
        }
    }

    public var wraps: Bool {
        get { gtk_label_get_wrap(pointer.cast()).isTrue }
        set { gtk_label_set_wrap(pointer.cast(), newValue.gbool) }
    }

    public var isSelectable: Bool {
        get { gtk_label_get_selectable(pointer.cast()).isTrue }
        set { gtk_label_set_selectable(pointer.cast(), newValue.gbool) }
    }
}

/// A `GtkImage` showing a themed icon.
@MainActor
public final class Image: Widget {
    public init(iconName: String, pixelSize: Int32? = nil) {
        super.init(rawPtr(gtk_image_new_from_icon_name(iconName))!)
        if let pixelSize { self.pixelSize = pixelSize }
    }

    public var iconName: String? {
        get { borrowedString(gtk_image_get_icon_name(pointer.cast())) }
        set { gtk_image_set_from_icon_name(pointer.cast(), newValue) }
    }

    public var pixelSize: Int32 {
        get { gtk_image_get_pixel_size(pointer.cast()) }
        set { gtk_image_set_pixel_size(pointer.cast(), newValue) }
    }
}

/// A `GtkEntry`.
@MainActor
public final class Entry: Widget {
    public init(text: String = "", placeholder: String? = nil) {
        super.init(rawPtr(gtk_entry_new())!)
        self.text = text
        if let placeholder { gtk_entry_set_placeholder_text(pointer.cast(), placeholder) }
    }

    /// Text of any `GtkEditable`.
    public var text: String {
        get { borrowedString(gtk_editable_get_text(pointer.cast())) ?? "" }
        set { gtk_editable_set_text(pointer.cast(), newValue) }
    }

    public func onChanged(_ body: @escaping @MainActor () -> Void) { connect("changed", body) }
    /// Enter pressed.
    public func onActivate(_ body: @escaping @MainActor () -> Void) { connect("activate", body) }
}

/// A `GtkSearchEntry` (debounced `search-changed`).
@MainActor
public final class SearchEntry: Widget {
    public init(placeholder: String? = nil) {
        super.init(rawPtr(gtk_search_entry_new())!)
        if let placeholder { gtk_search_entry_set_placeholder_text(pointer.cast(), placeholder) }
    }

    public var text: String {
        get { borrowedString(gtk_editable_get_text(pointer.cast())) ?? "" }
        set { gtk_editable_set_text(pointer.cast(), newValue) }
    }

    public func onSearchChanged(_ body: @escaping @MainActor () -> Void) { connect("search-changed", body) }
    public func onActivate(_ body: @escaping @MainActor () -> Void) { connect("activate", body) }
    public func onStopSearch(_ body: @escaping @MainActor () -> Void) { connect("stop-search", body) }
}

/// A `GtkSwitch`.
@MainActor
public final class Switch: Widget {
    public init(isOn: Bool = false) {
        super.init(rawPtr(gtk_switch_new())!)
        self.isOn = isOn
    }

    public var isOn: Bool {
        get { gtk_switch_get_active(pointer.cast()).isTrue }
        set { gtk_switch_set_active(pointer.cast(), newValue.gbool) }
    }

    public func onToggled(_ body: @escaping @MainActor () -> Void) { onNotify("active", body) }
}

/// A `GtkProgressBar`.
@MainActor
public final class ProgressBar: Widget {
    public init() { super.init(rawPtr(gtk_progress_bar_new())!) }

    public var fraction: Double {
        get { gtk_progress_bar_get_fraction(pointer.cast()) }
        set { gtk_progress_bar_set_fraction(pointer.cast(), min(max(newValue, 0), 1)) }
    }

    public var text: String? {
        get { borrowedString(gtk_progress_bar_get_text(pointer.cast())) }
        set {
            gtk_progress_bar_set_text(pointer.cast(), newValue)
            gtk_progress_bar_set_show_text(pointer.cast(), (newValue != nil).gbool)
        }
    }

    /// Indeterminate progress: call repeatedly while work runs.
    public func pulse() { gtk_progress_bar_pulse(pointer.cast()) }
}

/// An `AdwSpinner` (animates only while mapped).
@MainActor
public final class Spinner: Widget {
    public init() { super.init(rawPtr(adw_spinner_new())!) }
}

// MARK: - Feedback

/// An `AdwStatusPage` (empty states, errors, onboarding).
@MainActor
public final class StatusPage: Widget {
    public init(title: String, description: String? = nil, iconName: String? = nil) {
        super.init(rawPtr(adw_status_page_new())!)
        self.title = title
        self.descriptionText = description
        if let iconName { adw_status_page_set_icon_name(pointer.cast(), iconName) }
    }

    public var title: String {
        get { borrowedString(adw_status_page_get_title(pointer.cast())) ?? "" }
        set { adw_status_page_set_title(pointer.cast(), newValue) }
    }

    public var descriptionText: String? {
        get { borrowedString(adw_status_page_get_description(pointer.cast())) }
        set { adw_status_page_set_description(pointer.cast(), newValue) }
    }

    public var iconName: String? {
        get { borrowedString(adw_status_page_get_icon_name(pointer.cast())) }
        set { adw_status_page_set_icon_name(pointer.cast(), newValue) }
    }

    public var child: Widget? {
        didSet { adw_status_page_set_child(pointer.cast(), child?.widget) }
    }
}

/// An `AdwBanner` (a strip under the header bar with an optional button).
@MainActor
public final class Banner: Widget {
    public init(_ title: String, buttonLabel: String? = nil) {
        super.init(rawPtr(adw_banner_new(title))!)
        if let buttonLabel { adw_banner_set_button_label(pointer.cast(), buttonLabel) }
    }

    public var title: String {
        get { borrowedString(adw_banner_get_title(pointer.cast())) ?? "" }
        set { adw_banner_set_title(pointer.cast(), newValue) }
    }

    public var isRevealed: Bool {
        get { adw_banner_get_revealed(pointer.cast()).isTrue }
        set { adw_banner_set_revealed(pointer.cast(), newValue.gbool) }
    }

    public func onButtonClicked(_ body: @escaping @MainActor () -> Void) { connect("button-clicked", body) }
}

/// An `AdwToastOverlay`; wrap the window content in one to show ``Toast``s.
@MainActor
public final class ToastOverlay: Widget {
    public init(_ child: Widget? = nil) {
        super.init(rawPtr(adw_toast_overlay_new())!)
        self.child = child
        adw_toast_overlay_set_child(pointer.cast(), child?.widget)
    }

    public var child: Widget? {
        didSet { adw_toast_overlay_set_child(pointer.cast(), child?.widget) }
    }

    public func show(_ toast: Toast) {
        // add_toast takes ownership of a reference.
        g_object_ref(toast.pointer)
        adw_toast_overlay_add_toast(pointer.cast(), toast.pointer.cast())
    }

    @discardableResult
    public func show(_ title: String, timeout: UInt32 = 3) -> Toast {
        let toast = Toast(title, timeout: timeout)
        show(toast)
        return toast
    }
}

/// An `AdwToast`.
@MainActor
public final class Toast: GObjectRef {
    public init(_ title: String, timeout: UInt32 = 3, buttonLabel: String? = nil) {
        super.init(rawPtr(adw_toast_new(title))!)
        adw_toast_set_timeout(pointer.cast(), timeout)
        if let buttonLabel { adw_toast_set_button_label(pointer.cast(), buttonLabel) }
    }

    public var title: String {
        get { borrowedString(adw_toast_get_title(pointer.cast())) ?? "" }
        set { adw_toast_set_title(pointer.cast(), newValue) }
    }

    /// Action run by the button instead of a closure (`win.undo`).
    public var actionName: String? {
        get { borrowedString(adw_toast_get_action_name(pointer.cast())) }
        set { adw_toast_set_action_name(pointer.cast(), newValue) }
    }

    public func dismiss() { adw_toast_dismiss(pointer.cast()) }
    public func onButtonClicked(_ body: @escaping @MainActor () -> Void) { connect("button-clicked", body) }
    public func onDismissed(_ body: @escaping @MainActor () -> Void) { connect("dismissed", body) }
}
