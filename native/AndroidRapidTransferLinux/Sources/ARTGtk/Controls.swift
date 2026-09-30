import CGtk

// More controls: toggles, check buttons, level bars, popovers, calendars,
// toggle groups, list boxes and clamps.

/// A `GtkEventControllerFocus`: keyboard focus entering or leaving the
/// widget or its descendants.
@MainActor
public final class FocusController: EventController {
    public init() { super.init(rawPtr(gtk_event_controller_focus_new())!) }

    public func onEnter(_ body: @escaping @MainActor () -> Void) { connect("enter", body) }
    public func onLeave(_ body: @escaping @MainActor () -> Void) { connect("leave", body) }
}

/// A `GtkEventControllerMotion` reporting the pointer entering and leaving.
@MainActor
public final class HoverController: EventController {
    public init() { super.init(rawPtr(gtk_event_controller_motion_new())!) }

    public func onEnter(_ body: @escaping @MainActor () -> Void) { connect("enter", body) }
    public func onLeave(_ body: @escaping @MainActor () -> Void) { connect("leave", body) }
}

/// A `GtkToggleButton` (icon or label). Buttons joined with ``join(_:)``
/// behave like radio buttons.
@MainActor
public final class ToggleButton: Widget {
    public init(iconName: String, tooltip: String? = nil) {
        super.init(rawPtr(gtk_toggle_button_new())!)
        gtk_button_set_icon_name(pointer.cast(), iconName)
        self.tooltip = tooltip
    }

    public init(_ label: String) {
        super.init(rawPtr(gtk_toggle_button_new_with_label(label))!)
    }

    public var isActive: Bool {
        get { gtk_toggle_button_get_active(pointer.cast()).isTrue }
        set { gtk_toggle_button_set_active(pointer.cast(), newValue.gbool) }
    }

    /// Makes the button reflect and toggle a stateful action (`win.x`).
    public var actionName: String? {
        get { borrowedString(gtk_actionable_get_action_name(pointer.cast())) }
        set { gtk_actionable_set_action_name(pointer.cast(), newValue) }
    }

    /// Joins this button to `other`'s group (at most one active).
    public func join(_ other: ToggleButton) {
        gtk_toggle_button_set_group(pointer.cast(), other.pointer.cast())
    }

    public func onToggled(_ body: @escaping @MainActor () -> Void) { connect("toggled", body) }
}

/// A `GtkCheckButton` with a label.
@MainActor
public final class CheckButton: Widget {
    public init(_ label: String, isActive: Bool = false) {
        super.init(rawPtr(gtk_check_button_new_with_label(label))!)
        self.isActive = isActive
    }

    public var isActive: Bool {
        get { gtk_check_button_get_active(pointer.cast()).isTrue }
        set { gtk_check_button_set_active(pointer.cast(), newValue.gbool) }
    }

    public func onToggled(_ body: @escaping @MainActor () -> Void) { connect("toggled", body) }
}

/// A `GtkLevelBar` in continuous mode over 0...1. Named offsets set the CSS
/// class of the filled block (`levelbar block.<name>`): the first offset at
/// or above the value wins.
@MainActor
public final class LevelBar: Widget {
    public init(offsets: [(name: String, value: Double)] = []) {
        super.init(rawPtr(gtk_level_bar_new_for_interval(0, 1))!)
        gtk_level_bar_set_mode(pointer.cast(), GTK_LEVEL_BAR_MODE_CONTINUOUS)
        if !offsets.isEmpty {
            for name in ["low", "high", "full"] { gtk_level_bar_remove_offset_value(pointer.cast(), name) }
            for offset in offsets { gtk_level_bar_add_offset_value(pointer.cast(), offset.name, offset.value) }
        }
    }

    public var value: Double {
        get { gtk_level_bar_get_value(pointer.cast()) }
        set { gtk_level_bar_set_value(pointer.cast(), min(max(newValue, 0), 1)) }
    }
}

/// A `GtkPopover` with a child; show it from a ``MenuButton`` or with
/// ``popup()`` after parenting it with ``attach(to:)``.
@MainActor
public final class Popover: Widget {
    public init(_ child: Widget? = nil) {
        super.init(rawPtr(gtk_popover_new())!)
        self.child = child
        gtk_popover_set_child(pointer.cast(), child?.widget)
    }

    public var child: Widget? {
        didSet { gtk_popover_set_child(pointer.cast(), child?.widget) }
    }

    /// Parents the popover to `parent` (unparented again when it goes).
    public func attach(to parent: Widget) {
        gtk_widget_set_parent(widget, parent.widget)
        let weak = WeakObject(pointer)
        parent.onDestroy { weak.withObject { gtk_widget_unparent($0.cast()) } }
    }

    public var hasArrow: Bool {
        get { gtk_popover_get_has_arrow(pointer.cast()).isTrue }
        set { gtk_popover_set_has_arrow(pointer.cast(), newValue.gbool) }
    }

    public func popup() { gtk_popover_popup(pointer.cast()) }
    public func popdown() { gtk_popover_popdown(pointer.cast()) }
    public func onClosed(_ body: @escaping @MainActor () -> Void) { connect("closed", body) }
}

extension MenuButton {
    /// A menu button showing an arbitrary popover, with an icon or a label
    /// (and optionally a custom child instead of either).
    public convenience init(iconName: String? = nil, label: String? = nil, popover: Popover) {
        self.init(iconName: iconName ?? "pan-down-symbolic", menu: Menu())
        gtk_menu_button_set_menu_model(pointer.cast(), nil)
        if let label { gtk_menu_button_set_label(pointer.cast(), label) }
        gtk_menu_button_set_popover(pointer.cast(), popover.widget)
    }

    /// Replaces the button's face with `child`.
    public func setChild(_ child: Widget) { gtk_menu_button_set_child(pointer.cast(), child.widget) }

    public var alwaysShowsArrow: Bool {
        get { gtk_menu_button_get_always_show_arrow(pointer.cast()).isTrue }
        set { gtk_menu_button_set_always_show_arrow(pointer.cast(), newValue.gbool) }
    }

    public var label: String? {
        get { borrowedString(gtk_menu_button_get_label(pointer.cast())) }
        set { gtk_menu_button_set_label(pointer.cast(), newValue) }
    }

    /// Replaces the menu model.
    public func setMenu(_ menu: Menu) { gtk_menu_button_set_menu_model(pointer.cast(), menu.pointer.cast()) }
}

/// A `GtkCalendar` (named so it does not clash with Foundation's `Calendar`).
@MainActor
public final class CalendarView: Widget {
    public init() { super.init(rawPtr(gtk_calendar_new())!) }

    /// The selected day as (year, month 1...12, day 1...31).
    public var selectedDay: (year: Int, month: Int, day: Int) {
        get {
            guard let date = gtk_calendar_get_date(pointer.cast()) else { return (1970, 1, 1) }
            defer { g_date_time_unref(date) }
            return (Int(g_date_time_get_year(date)), Int(g_date_time_get_month(date)), Int(g_date_time_get_day_of_month(date)))
        }
        set {
            guard let date = g_date_time_new_local(Int32(newValue.year), Int32(newValue.month), Int32(newValue.day), 12, 0, 0) else { return }
            gtk_calendar_set_date(pointer.cast(), date)
            g_date_time_unref(date)
        }
    }

    public func onDaySelected(_ body: @escaping @MainActor () -> Void) { connect("day-selected", body) }
}

/// An `AdwToggleGroup`: a row of mutually exclusive toggles, each named.
@MainActor
public final class ToggleGroup: Widget {
    public init() { super.init(rawPtr(adw_toggle_group_new())!) }

    /// Adds a toggle showing an icon (or a label when `iconName` is nil).
    public func add(name: String, iconName: String? = nil, label: String? = nil, tooltip: String? = nil) {
        let toggle = adw_toggle_new()!
        adw_toggle_set_name(toggle, name)
        if let iconName { adw_toggle_set_icon_name(toggle, iconName) }
        if let label { adw_toggle_set_label(toggle, label) }
        if let tooltip { adw_toggle_set_tooltip(toggle, tooltip) }
        adw_toggle_group_add(pointer.cast(), toggle) // takes ownership
    }

    public var activeName: String? {
        get { borrowedString(adw_toggle_group_get_active_name(pointer.cast())) }
        set { if let newValue { adw_toggle_group_set_active_name(pointer.cast(), newValue) } }
    }

    /// Changes the label of the toggle called `name`.
    public func setToggleLabel(name: String, _ label: String) {
        guard let toggle = adw_toggle_group_get_toggle_by_name(pointer.cast(), name) else { return }
        adw_toggle_set_label(toggle, label)
    }

    public var isHomogeneous: Bool {
        get { adw_toggle_group_get_homogeneous(pointer.cast()).isTrue }
        set { adw_toggle_group_set_homogeneous(pointer.cast(), newValue.gbool) }
    }

    public func onActiveChanged(_ body: @escaping @MainActor () -> Void) { onNotify("active-name", body) }
}

/// A `GtkListBox` (with the `boxed-list` style for preference-like rows).
@MainActor
public final class ListBox: Widget {
    public init(boxed: Bool = true) {
        super.init(rawPtr(gtk_list_box_new())!)
        gtk_list_box_set_selection_mode(pointer.cast(), GTK_SELECTION_NONE)
        if boxed { addCSSClass("boxed-list") }
    }

    public func append(_ row: Widget) { gtk_list_box_append(pointer.cast(), row.widget) }
    public func removeAll() { gtk_list_box_remove_all(pointer.cast()) }
}

/// An `AdwClamp`: limits its child's width and centres it.
@MainActor
public final class Clamp: Widget {
    public init(_ child: Widget? = nil, maximumSize: Int32 = 600) {
        super.init(rawPtr(adw_clamp_new())!)
        adw_clamp_set_maximum_size(pointer.cast(), maximumSize)
        self.child = child
        adw_clamp_set_child(pointer.cast(), child?.widget)
    }

    public var child: Widget? {
        didSet { adw_clamp_set_child(pointer.cast(), child?.widget) }
    }
}

/// An `AdwExpanderRow` (a preferences row that reveals nested rows).
@MainActor
public final class ExpanderRow: Widget {
    public init(title: String, subtitle: String? = nil) {
        super.init(rawPtr(adw_expander_row_new())!)
        adw_preferences_row_set_title(pointer.cast(), title)
        if let subtitle { adw_expander_row_set_subtitle(pointer.cast(), subtitle) }
    }

    public func addRow(_ row: Widget) { adw_expander_row_add_row(pointer.cast(), row.widget) }
    public func addPrefix(_ widget: Widget) { adw_expander_row_add_prefix(pointer.cast(), widget.widget) }
    public func addSuffix(_ widget: Widget) { adw_expander_row_add_suffix(pointer.cast(), widget.widget) }

    public var isExpanded: Bool {
        get { adw_expander_row_get_expanded(pointer.cast()).isTrue }
        set { adw_expander_row_set_expanded(pointer.cast(), newValue.gbool) }
    }
}

/// An `AdwComboRow` choosing among plain strings.
@MainActor
public final class ComboRow: Widget {
    public init(title: String, subtitle: String? = nil, choices: [String]) {
        super.init(rawPtr(adw_combo_row_new())!)
        adw_preferences_row_set_title(pointer.cast(), title)
        if let subtitle { adw_action_row_set_subtitle(pointer.cast(), subtitle) }
        let list = withCStringArray(choices) { gtk_string_list_new($0) }
        adw_combo_row_set_model(pointer.cast(), UnsafeMutableRawPointer(list!).cast())
        g_object_unref(UnsafeMutableRawPointer(list!))
    }

    public var selectedIndex: Int {
        get { Int(adw_combo_row_get_selected(pointer.cast())) }
        set { adw_combo_row_set_selected(pointer.cast(), UInt32(newValue)) }
    }

    public func onSelectionChanged(_ body: @escaping @MainActor () -> Void) { onNotify("selected", body) }
}

/// An `AdwEntryRow` (a preferences row that is a text field).
@MainActor
public final class EntryRow: Widget {
    public init(title: String, text: String = "") {
        super.init(rawPtr(adw_entry_row_new())!)
        adw_preferences_row_set_title(pointer.cast(), title)
        self.text = text
    }

    public var text: String {
        get { borrowedString(gtk_editable_get_text(pointer.cast())) ?? "" }
        set { gtk_editable_set_text(pointer.cast(), newValue) }
    }

    public func onChanged(_ body: @escaping @MainActor () -> Void) { connect("changed", body) }
    /// Enter pressed.
    public func onEntryActivated(_ body: @escaping @MainActor () -> Void) { connect("entry-activated", body) }
    public func addSuffix(_ widget: Widget) { adw_entry_row_add_suffix(pointer.cast(), widget.widget) }
}

/// An `AdwButtonRow` (a full-width button in a boxed list).
@MainActor
public final class ButtonRow: Widget {
    public init(title: String, iconName: String? = nil) {
        super.init(rawPtr(adw_button_row_new())!)
        adw_preferences_row_set_title(pointer.cast(), title)
        if let iconName { adw_button_row_set_start_icon_name(pointer.cast(), iconName) }
    }

    public func onActivated(_ body: @escaping @MainActor () -> Void) { connect("activated", body) }
}

extension Button {
    /// A button whose face is an arbitrary widget.
    public convenience init(child: Widget) {
        self.init("")
        gtk_button_set_child(pointer.cast(), child.widget)
    }

    /// Replaces the icon + label content (`AdwButtonContent`).
    public func setContent(label: String, iconName: String) {
        let content = adw_button_content_new()!
        adw_button_content_set_label(UnsafeMutableRawPointer(content).cast(), label)
        adw_button_content_set_icon_name(UnsafeMutableRawPointer(content).cast(), iconName)
        gtk_button_set_child(pointer.cast(), content)
    }

    public var hasFrame: Bool {
        get { gtk_button_get_has_frame(pointer.cast()).isTrue }
        set { gtk_button_set_has_frame(pointer.cast(), newValue.gbool) }
    }
}

extension Stack {
    /// The page added under `name`, if any.
    public func child(named name: String) -> Widget? {
        guard let child = gtk_stack_get_child_by_name(pointer.cast(), name) else { return nil }
        return borrowWidget(UnsafeMutableRawPointer(child))
    }

    public func remove(_ child: Widget) { gtk_stack_remove(pointer.cast(), child.widget) }

    /// False lets the stack take each page's own height (and animate between them).
    public var isVerticallyHomogeneous: Bool {
        get { gtk_stack_get_vhomogeneous(pointer.cast()).isTrue }
        set {
            gtk_stack_set_vhomogeneous(pointer.cast(), newValue.gbool)
            gtk_stack_set_interpolate_size(pointer.cast(), (!newValue).gbool)
        }
    }
}

extension Entry {
    /// Selects characters `start..<end` (-1 = to the end).
    public func selectRegion(start: Int, end: Int) {
        gtk_editable_select_region(pointer.cast(), Int32(start), Int32(end))
    }
}

extension Box {
    /// Removes every child.
    public func removeAllChildren() {
        while let child = gtk_widget_get_first_child(widget) {
            gtk_box_remove(pointer.cast(), child)
        }
    }
}

extension Label {
    /// A label with wrapping and centred or leading text in one call.
    public var justifyCenter: Bool {
        get { gtk_label_get_justify(pointer.cast()) == GTK_JUSTIFY_CENTER }
        set { gtk_label_set_justify(pointer.cast(), newValue ? GTK_JUSTIFY_CENTER : GTK_JUSTIFY_LEFT) }
    }

    public var maxWidthChars: Int32 {
        get { gtk_label_get_max_width_chars(pointer.cast()) }
        set { gtk_label_set_max_width_chars(pointer.cast(), newValue) }
    }

    public var lines: Int32 {
        get { gtk_label_get_lines(pointer.cast()) }
        set { gtk_label_set_lines(pointer.cast(), newValue) }
    }
}

extension Image {
    /// A themed icon from several candidate names (the first the theme has wins).
    public func setIconNames(_ names: [String]) {
        var copies: [UnsafeMutablePointer<CChar>?] = names.map { strdup($0) } + [nil]
        defer { copies.forEach { free($0) } }
        let icon = copies.withUnsafeMutableBufferPointer { g_themed_icon_new_from_names($0.baseAddress, -1) }
        gtk_image_set_from_gicon(pointer.cast(), icon)
        if let icon { g_object_unref(UnsafeMutableRawPointer(icon)) }
    }
}

extension Widget {
    /// The deepest widget at (`x`, `y`) in this widget's coordinates.
    public func pick(x: Double, y: Double) -> UnsafeMutableRawPointer? {
        rawPtr(gtk_widget_pick(widget, x, y, GTK_PICK_DEFAULT))
    }

    /// The associated object stored under `key` on the widget at `pointer` or
    /// the nearest ancestor that has one (for finding the row under a click).
    public static func nearestAssociated(from pointer: UnsafeMutableRawPointer?, forKey key: String) -> AnyObject? {
        var current = pointer.map { UnsafeMutablePointer<GtkWidget>($0.assumingMemoryBound(to: GtkWidget.self)) }
        while let widget = current {
            if let value = GObjectRef.associated(on: UnsafeMutableRawPointer(widget), forKey: key) { return value }
            current = gtk_widget_get_parent(widget)
        }
        return nil
    }

    /// Whether keyboard focus is in this widget or one of its descendants.
    public var containsFocus: Bool {
        guard let root = gtk_widget_get_root(widget), let focus = gtk_root_get_focus(root) else { return false }
        return focus == widget || gtk_widget_is_ancestor(focus, widget).isTrue
    }

    /// Makes `name` the mouse cursor over this widget (nil = default).
    public func setCursor(named name: String?) { gtk_widget_set_cursor_from_name(widget, name) }

    /// Sets the widget's accessible label (screen readers).
    public func setAccessibleLabel(_ label: String) {
        var properties: [GtkAccessibleProperty] = [GTK_ACCESSIBLE_PROPERTY_LABEL]
        var values = [GValue()]
        g_value_init(&values[0], art_type_string())
        g_value_set_string(&values[0], label)
        gtk_accessible_update_property_value(OpaquePointer(pointer), 1, &properties, &values)
        g_value_unset(&values[0])
    }
}
