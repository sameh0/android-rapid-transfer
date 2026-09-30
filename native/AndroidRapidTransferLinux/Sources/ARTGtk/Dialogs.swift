import CGtk

/// Hands a GAsyncReadyCallback result back to a boxed Swift closure.
private typealias AsyncDone = @MainActor (UnsafeMutableRawPointer?, OpaquePointer?) -> Void

private let asyncReadyTrampoline: GAsyncReadyCallback = { source, result, data in
    let box = Boxed<AsyncDone>.take(data!)
    nonisolated(unsafe) let source = rawPtr(source)
    nonisolated(unsafe) let result = result
    onMain { box.value(source, result) }
}

/// The Swift error for a `GError`.
public struct GLibError: Error, CustomStringConvertible, Sendable {
    public let domain: String
    public let code: Int32
    public let message: String
    public var description: String { "\(domain) \(code): \(message)" }

    /// Consumes (frees) `error`.
    init(taking error: UnsafeMutablePointer<GError>) {
        domain = String(cString: g_quark_to_string(error.pointee.domain))
        code = error.pointee.code
        message = String(cString: error.pointee.message)
        g_error_free(error)
    }

    /// A dialog the user dismissed (cancel, Escape, closing it).
    public var isDismissal: Bool {
        (domain == "gtk-dialog-error-quark" && (code == Int32(GTK_DIALOG_ERROR_DISMISSED.rawValue) || code == Int32(GTK_DIALOG_ERROR_CANCELLED.rawValue)))
            || (domain == "g-io-error-quark" && code == Int32(G_IO_ERROR_CANCELLED.rawValue))
    }
}

// MARK: - Alert

/// An `AdwAlertDialog` with an async result.
///
///     let alert = AlertDialog(heading: "Replace file?", body: "“a.jpg” exists.")
///     alert.addResponse("cancel", "Cancel")
///     alert.addResponse("replace", "Replace", appearance: .destructive)
///     if await alert.choose(parent: window) == "replace" { … }
@MainActor
public final class AlertDialog: Widget {
    public enum Appearance: Sendable {
        case `default`, suggested, destructive
        var adw: AdwResponseAppearance {
            switch self {
            case .default: ADW_RESPONSE_DEFAULT
            case .suggested: ADW_RESPONSE_SUGGESTED
            case .destructive: ADW_RESPONSE_DESTRUCTIVE
            }
        }
    }

    public init(heading: String, body: String? = nil) {
        super.init(rawPtr(adw_alert_dialog_new(heading, body))!)
    }

    public func addResponse(_ id: String, _ label: String, appearance: Appearance = .default) {
        adw_alert_dialog_add_response(pointer.cast(), id, label)
        if appearance != .default { adw_alert_dialog_set_response_appearance(pointer.cast(), id, appearance.adw) }
    }

    /// Response chosen by Enter.
    public var defaultResponse: String? {
        get { borrowedString(adw_alert_dialog_get_default_response(pointer.cast())) }
        set { adw_alert_dialog_set_default_response(pointer.cast(), newValue) }
    }

    /// Response reported when the dialog is closed (Escape, or ``close()``).
    public var closeResponse: String {
        get { borrowedString(adw_alert_dialog_get_close_response(pointer.cast())) ?? "close" }
        set { adw_alert_dialog_set_close_response(pointer.cast(), newValue) }
    }

    public var extraChild: Widget? {
        didSet { adw_alert_dialog_set_extra_child(pointer.cast(), extraChild?.widget) }
    }

    /// Presents the dialog over `parent` and returns the chosen response id.
    public func choose(parent: Widget?) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let done: AsyncDone = { [self] _, result in
                let response = borrowedString(adw_alert_dialog_choose_finish(pointer.cast(), result)) ?? closeResponse
                continuation.resume(returning: response)
            }
            adw_alert_dialog_choose(pointer.cast(), parent?.widget, nil, asyncReadyTrampoline, Boxed(done).retainedPointer())
        }
    }

    /// Closes the dialog; ``choose(parent:)`` returns ``closeResponse``.
    public func close() { adw_dialog_close(pointer.cast()) }
}

// MARK: - File chooser

/// A `GtkFileDialog` (the portal file chooser when available).
///
///     if let folder = try await FileDialog(title: "Copy to").selectFolder(parent: window) { … }
@MainActor
public final class FileDialog: GObjectRef {
    public init(title: String? = nil, acceptLabel: String? = nil) {
        super.init(rawPtr(gtk_file_dialog_new())!)
        if let title { gtk_file_dialog_set_title(pointer.cast(), title) }
        if let acceptLabel { gtk_file_dialog_set_accept_label(pointer.cast(), acceptLabel) }
    }

    /// Starts in `path`.
    public func setInitialFolder(_ path: String) {
        let file = g_file_new_for_path(path)
        gtk_file_dialog_set_initial_folder(pointer.cast(), file)
        g_object_unref(UnsafeMutableRawPointer(file))
    }

    /// A folder path, or nil if the user cancelled.
    public func selectFolder(parent: Window?) async throws -> String? {
        try await run(parent: parent, start: { gtk_file_dialog_select_folder($0, $1, nil, asyncReadyTrampoline, $2) },
                      finish: { gtk_file_dialog_select_folder_finish($0, $1, $2) })
    }

    /// A file path to open, or nil if cancelled.
    public func openFile(parent: Window?) async throws -> String? {
        try await run(parent: parent, start: { gtk_file_dialog_open($0, $1, nil, asyncReadyTrampoline, $2) },
                      finish: { gtk_file_dialog_open_finish($0, $1, $2) })
    }

    /// A destination path to save to, or nil if cancelled.
    public func save(parent: Window?, suggestedName: String? = nil) async throws -> String? {
        if let suggestedName { gtk_file_dialog_set_initial_name(pointer.cast(), suggestedName) }
        return try await run(parent: parent, start: { gtk_file_dialog_save($0, $1, nil, asyncReadyTrampoline, $2) },
                             finish: { gtk_file_dialog_save_finish($0, $1, $2) })
    }

    private typealias Start = (OpaquePointer, UnsafeMutablePointer<GtkWindow>?, UnsafeMutableRawPointer) -> Void
    private typealias Finish = (OpaquePointer, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>) -> OpaquePointer?

    private func run(parent: Window?, start: Start, finish: @escaping Finish) async throws -> String? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
            let done: AsyncDone = { [self] _, result in
                var error: UnsafeMutablePointer<GError>?
                if let file = finish(pointer.cast(), result, &error) {
                    let path = takenString(g_file_get_path(file)) ?? takenString(g_file_get_uri(file))
                    g_object_unref(UnsafeMutableRawPointer(file))
                    continuation.resume(returning: path)
                } else if let error {
                    let swiftError = GLibError(taking: error)
                    swiftError.isDismissal ? continuation.resume(returning: nil) : continuation.resume(throwing: swiftError)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            start(pointer.cast(), parent?.pointer.cast(), Boxed(done).retainedPointer())
        }
    }
}

// MARK: - Preferences

/// An `AdwPreferencesDialog`.
@MainActor
public final class PreferencesDialog: Widget {
    public init() { super.init(rawPtr(adw_preferences_dialog_new())!) }

    public func add(_ page: PreferencesPage) { adw_preferences_dialog_add(pointer.cast(), page.pointer.cast()) }
    public func present(parent: Widget?) { adw_dialog_present(pointer.cast(), parent?.widget) }
    public func close() { adw_dialog_close(pointer.cast()) }
}

/// An `AdwPreferencesPage`.
@MainActor
public final class PreferencesPage: Widget {
    public init(title: String, iconName: String? = nil) {
        super.init(rawPtr(adw_preferences_page_new())!)
        adw_preferences_page_set_title(pointer.cast(), title)
        if let iconName { adw_preferences_page_set_icon_name(pointer.cast(), iconName) }
    }

    public func add(_ group: PreferencesGroup) { adw_preferences_page_add(pointer.cast(), group.pointer.cast()) }
}

/// An `AdwPreferencesGroup`.
@MainActor
public final class PreferencesGroup: Widget {
    public init(title: String, description: String? = nil) {
        super.init(rawPtr(adw_preferences_group_new())!)
        adw_preferences_group_set_title(pointer.cast(), title)
        if let description { adw_preferences_group_set_description(pointer.cast(), description) }
    }

    public func add(_ row: Widget) { adw_preferences_group_add(pointer.cast(), row.widget) }
}

/// An `AdwSwitchRow`.
@MainActor
public final class SwitchRow: Widget {
    public init(title: String, subtitle: String? = nil, isOn: Bool = false) {
        super.init(rawPtr(adw_switch_row_new())!)
        adw_preferences_row_set_title(pointer.cast(), title)
        if let subtitle { adw_action_row_set_subtitle(pointer.cast(), subtitle) }
        self.isOn = isOn
    }

    public var isOn: Bool {
        get { adw_switch_row_get_active(pointer.cast()).isTrue }
        set { adw_switch_row_set_active(pointer.cast(), newValue.gbool) }
    }

    public func onToggled(_ body: @escaping @MainActor () -> Void) { onNotify("active", body) }
}

/// An `AdwActionRow` (title, subtitle, suffix widgets).
@MainActor
public final class ActionRow: Widget {
    public init(title: String, subtitle: String? = nil) {
        super.init(rawPtr(adw_action_row_new())!)
        adw_preferences_row_set_title(pointer.cast(), title)
        if let subtitle { adw_action_row_set_subtitle(pointer.cast(), subtitle) }
    }

    public func addSuffix(_ widget: Widget) { adw_action_row_add_suffix(pointer.cast(), widget.widget) }
    public func addPrefix(_ widget: Widget) { adw_action_row_add_prefix(pointer.cast(), widget.widget) }

    public var subtitle: String? {
        get { borrowedString(adw_action_row_get_subtitle(pointer.cast())) }
        set { adw_action_row_set_subtitle(pointer.cast(), newValue) }
    }
}
