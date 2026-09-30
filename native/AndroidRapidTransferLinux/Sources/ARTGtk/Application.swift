import CGtk
import Glibc

/// An `AdwApplication`. Call ``run(arguments:)`` from `main`; build the UI in
/// ``onActivate(_:)``.
///
///     let app = Application(id: "com.example.App")
///     app.onActivate { let window = ApplicationWindow(application: app); window.present() }
///     exit(app.run())
@MainActor
public final class Application: GObjectRef, ActionMap {
    /// - Parameter unique: false lets several instances run (no D-Bus name
    ///   ownership); tests and demos use that.
    public init(id: String, unique: Bool = true) {
        let flags = GApplicationFlags(rawValue: unique ? 0 : 1 << 5) // G_APPLICATION_NON_UNIQUE
        super.init(rawPtr(adw_application_new(id, flags))!)
    }

    public var gapplication: OpaquePointer { pointer.cast() }

    public func onStartup(_ body: @escaping @MainActor () -> Void) { connect("startup", body) }
    public func onActivate(_ body: @escaping @MainActor () -> Void) { connect("activate", body) }
    public func onShutdown(_ body: @escaping @MainActor () -> Void) { connect("shutdown", body) }

    /// Installs the main-actor bridge and runs the GLib main loop until the
    /// application quits. Only `argv[0]` is passed to GApplication by default,
    /// so the caller's own flags don't trip GApplication's option parser.
    public func run(arguments: [String] = [CommandLine.arguments.first ?? "app"]) -> Int32 {
        MainLoopBridge.install()
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        return argv.withUnsafeMutableBufferPointer { buffer in
            g_application_run(pointer.cast(), Int32(arguments.count), buffer.baseAddress)
        }
    }

    public func quit() { g_application_quit(pointer.cast()) }

    /// Keeps the app running with no windows open (balance with ``release()``).
    public func hold() { g_application_hold(pointer.cast()) }
    public func release() { g_application_release(pointer.cast()) }

    /// Binds keyboard accelerators (GTK syntax, e.g. `<Control>q`) to a
    /// detailed action name (`app.quit`, `win.copy`).
    public func setAccelerators(_ accelerators: [String], for detailedAction: String) {
        withCStringArray(accelerators) { gtk_application_set_accels_for_action(pointer.cast(), detailedAction, $0) }
    }

    /// Sends a desktop notification (`GNotification`). Needs a matching
    /// `.desktop` file for the app id to show the right name and icon.
    public func send(_ notification: DesktopNotification, id: String? = nil) {
        g_application_send_notification(pointer.cast(), id, notification.pointer.cast())
    }

    public func withdrawNotification(id: String) {
        g_application_withdraw_notification(pointer.cast(), id)
    }

    /// The window that last had focus.
    public var activeWindowPointer: UnsafeMutableRawPointer? {
        rawPtr(gtk_application_get_active_window(pointer.cast()))
    }
}

/// A `GNotification`.
@MainActor
public final class DesktopNotification: GObjectRef {
    public init(title: String, body: String? = nil, iconName: String? = nil) {
        super.init(rawPtr(g_notification_new(title))!)
        if let body { g_notification_set_body(pointer.cast(), body) }
        if let iconName, let icon = g_themed_icon_new(iconName) {
            g_notification_set_icon(pointer.cast(), icon)
            g_object_unref(UnsafeMutableRawPointer(icon))
        }
    }

    /// Sets the action run when the notification is clicked (`app.*`).
    public func setDefaultAction(_ detailedAction: String) {
        g_notification_set_default_action(pointer.cast(), detailedAction)
    }

    public func addButton(_ label: String, action detailedAction: String) {
        g_notification_add_button(pointer.cast(), label, detailedAction)
    }
}

// MARK: - Actions

/// Something that holds actions: the application (`app.` prefix), an
/// application window (`win.`) or an ``ActionGroup`` inserted on a widget.
@MainActor
public protocol ActionMap: GObjectRef {}

extension ActionMap {
    public func add(_ action: SimpleAction) {
        g_action_map_add_action(pointer.cast(), action.pointer.cast())
    }

    /// Creates, adds and returns a plain action.
    @discardableResult
    public func addAction(_ name: String, _ handler: @escaping @MainActor () -> Void) -> SimpleAction {
        let action = SimpleAction(name, handler)
        add(action)
        return action
    }

    public func removeAction(_ name: String) {
        g_action_map_remove_action(pointer.cast(), name)
    }
}

/// A `GSimpleActionGroup`, to insert on a widget under a prefix
/// (``Widget/insertActionGroup(_:prefix:)``) for scoped actions.
@MainActor
public final class ActionGroup: GObjectRef, ActionMap {
    public init() { super.init(rawPtr(g_simple_action_group_new())!) }
}

/// A `GSimpleAction`, stateless or with a boolean state (a toggle).
@MainActor
public final class SimpleAction: GObjectRef {
    public let name: String

    /// A plain action.
    public init(_ name: String, _ handler: @escaping @MainActor () -> Void) {
        self.name = name
        super.init(rawPtr(g_simple_action_new(name, nil))!)
        connect("activate", handler)
    }

    /// A toggle: activating flips the state and reports the new value. Shows
    /// as a check item in menus.
    public init(_ name: String, state: Bool, _ handler: @escaping @MainActor (Bool) -> Void) {
        self.name = name
        super.init(rawPtr(g_simple_action_new_stateful(name, nil, g_variant_new_boolean(state.gbool)))!)
        let weak = WeakObject(pointer)
        connect("activate") {
            weak.withObject { p in
                let current = g_action_get_state(p.cast())
                let newValue = !(current.map { g_variant_get_boolean($0).isTrue } ?? false)
                if let current { g_variant_unref(current) }
                g_simple_action_set_state(p.cast(), g_variant_new_boolean(newValue.gbool))
                handler(newValue)
            }
        }
    }

    public var isEnabled: Bool {
        get { g_action_get_enabled(pointer.cast()).isTrue }
        set { g_simple_action_set_enabled(pointer.cast(), newValue.gbool) }
    }

    /// The boolean state of a toggle action (false for stateless actions).
    public var boolState: Bool {
        get {
            guard let state = g_action_get_state(pointer.cast()) else { return false }
            defer { g_variant_unref(state) }
            return g_variant_get_boolean(state).isTrue
        }
        set { g_simple_action_set_state(pointer.cast(), g_variant_new_boolean(newValue.gbool)) }
    }

    /// Activates the action as if a menu item or accelerator had.
    public func activate() { g_action_activate(pointer.cast(), nil) }
}

// MARK: - Menus

/// A `GMenu` model for popover menus, menu buttons and context menus.
///
///     let menu = Menu()
///     menu.append("Copy", action: "win.copy")
///     menu.appendSection(Menu().appending("Quit", action: "app.quit"))
@MainActor
public final class Menu: GObjectRef {
    public init() { super.init(rawPtr(g_menu_new())!) }

    public func append(_ label: String, action detailedAction: String?) {
        g_menu_append(pointer.cast(), label, detailedAction)
    }

    @discardableResult
    public func appending(_ label: String, action detailedAction: String?) -> Menu {
        append(label, action: detailedAction)
        return self
    }

    public func appendSection(_ section: Menu, label: String? = nil) {
        g_menu_append_section(pointer.cast(), label, section.pointer.cast())
    }

    public func appendSubmenu(_ submenu: Menu, label: String) {
        g_menu_append_submenu(pointer.cast(), label, submenu.pointer.cast())
    }

    public var itemCount: Int { Int(g_menu_model_get_n_items(pointer.cast())) }
}
