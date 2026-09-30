import CGtk

/// A `GtkShortcutController` binding key triggers to closures on one widget.
///
/// Unlike application accelerators, these only fire while focus is inside
/// the widget (``Scope/local``), so a pane can own Ctrl+C / Delete without
/// stealing them from text fields elsewhere.
///
///     let keys = ShortcutController()
///     keys.add("Delete") { deleteSelection(); return true }
///     table.add(keys)
@MainActor
public final class ShortcutController: EventController {
    public enum Scope: Sendable { case local, managed, global }

    public init(scope: Scope = .local) {
        super.init(rawPtr(gtk_shortcut_controller_new())!)
        let value: GtkShortcutScope = switch scope {
        case .local: GTK_SHORTCUT_SCOPE_LOCAL
        case .managed: GTK_SHORTCUT_SCOPE_MANAGED
        case .global: GTK_SHORTCUT_SCOPE_GLOBAL
        }
        gtk_shortcut_controller_set_scope(pointer.cast(), value)
    }

    public typealias Handler = @MainActor () -> Bool

    /// Binds `trigger` (GTK syntax: `<Control>c`, `Delete`, `F2`,
    /// `<Alt>Up`; several separated by `|`) to `handler`, which returns
    /// whether it handled the key.
    public func add(_ trigger: String, _ handler: @escaping Handler) {
        guard let parsed = gtk_shortcut_trigger_parse_string(trigger) else {
            assertionFailure("invalid shortcut trigger \(trigger)")
            return
        }
        let callback: GtkShortcutFunc = { _, _, data in
            let box = Boxed<Handler>.borrow(data!)
            return onMain { box.value() }.gbool
        }
        let action = gtk_callback_action_new(callback, Boxed(handler).retainedPointer(), releaseNotify)
        // gtk_shortcut_new takes ownership of the trigger and the action.
        gtk_shortcut_controller_add_shortcut(pointer.cast(), gtk_shortcut_new(parsed, action))
    }
}
