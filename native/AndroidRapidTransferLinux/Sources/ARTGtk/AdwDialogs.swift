import CGtk

/// An `AdwDialog`: a sheet over its parent window (or a floating window on
/// wide screens) holding any content. Put an ``ToolbarView`` with a
/// ``HeaderBar`` inside for a title and close button.
///
///     let dialog = Dialog(title: "Copy by Date Range", width: 520)
///     dialog.child = toolbarView
///     dialog.present(parent: window)
@MainActor
open class Dialog: Widget {
    public init(title: String = "", width: Int32 = -1, height: Int32 = -1) {
        super.init(rawPtr(adw_dialog_new())!)
        adw_dialog_set_title(pointer.cast(), title)
        if width > 0 { adw_dialog_set_content_width(pointer.cast(), width) }
        if height > 0 { adw_dialog_set_content_height(pointer.cast(), height) }
    }

    /// Wraps a dialog made by another constructor (subclasses).
    public init(dialogPointer: UnsafeMutableRawPointer) {
        super.init(dialogPointer)
    }

    public var child: Widget? {
        didSet { adw_dialog_set_child(pointer.cast(), child?.widget) }
    }

    public var title: String {
        get { borrowedString(adw_dialog_get_title(pointer.cast())) ?? "" }
        set { adw_dialog_set_title(pointer.cast(), newValue) }
    }

    /// False keeps the dialog open on Escape / the close button (the
    /// `close-attempt` signal fires instead).
    public var canClose: Bool {
        get { adw_dialog_get_can_close(pointer.cast()).isTrue }
        set { adw_dialog_set_can_close(pointer.cast(), newValue.gbool) }
    }

    public var followsContentSize: Bool {
        get { adw_dialog_get_follows_content_size(pointer.cast()).isTrue }
        set { adw_dialog_set_follows_content_size(pointer.cast(), newValue.gbool) }
    }

    public func setContentSize(width: Int32, height: Int32) {
        adw_dialog_set_content_width(pointer.cast(), width)
        adw_dialog_set_content_height(pointer.cast(), height)
    }

    /// The widget activated by Enter.
    public func setDefaultWidget(_ widget: Widget?) { adw_dialog_set_default_widget(pointer.cast(), widget?.widget) }

    /// The widget focused when the dialog opens.
    public func setFocus(_ widget: Widget?) { adw_dialog_set_focus(pointer.cast(), widget?.widget) }

    public func present(parent: Widget?) { adw_dialog_present(pointer.cast(), parent?.widget) }
    @discardableResult
    public func close() -> Bool { adw_dialog_close(pointer.cast()).isTrue }
    public func forceClose() { adw_dialog_force_close(pointer.cast()) }

    public func onClosed(_ body: @escaping @MainActor () -> Void) { connect("closed", body) }
    public func onCloseAttempt(_ body: @escaping @MainActor () -> Void) { connect("close-attempt", body) }
}

extension PreferencesDialog {
    public func onClosed(_ body: @escaping @MainActor () -> Void) { connect("closed", body) }

    public var searchEnabled: Bool {
        get { adw_preferences_dialog_get_search_enabled(pointer.cast()).isTrue }
        set { adw_preferences_dialog_set_search_enabled(pointer.cast(), newValue.gbool) }
    }
}

extension AlertDialog {
    /// Greys a response out (for example Save while a name is invalid).
    public func setResponseEnabled(_ id: String, _ enabled: Bool) {
        adw_alert_dialog_set_response_enabled(pointer.cast(), id, enabled.gbool)
    }

    public var body: String {
        get { borrowedString(adw_alert_dialog_get_body(pointer.cast())) ?? "" }
        set { adw_alert_dialog_set_body(pointer.cast(), newValue) }
    }

    public var heading: String {
        get { borrowedString(adw_alert_dialog_get_heading(pointer.cast())) ?? "" }
        set { adw_alert_dialog_set_heading(pointer.cast(), newValue) }
    }

    /// Lets the text wrap wide content (long paths) instead of growing.
    public var preferWideLayout: Bool {
        get { adw_alert_dialog_get_prefer_wide_layout(pointer.cast()).isTrue }
        set { adw_alert_dialog_set_prefer_wide_layout(pointer.cast(), newValue.gbool) }
    }
}

/// An `AdwAboutDialog`.
@MainActor
public final class AboutDialog: Dialog {
    public init() { super.init(dialogPointer: rawPtr(adw_about_dialog_new())!) }

    public var applicationName: String {
        get { borrowedString(adw_about_dialog_get_application_name(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_application_name(pointer.cast(), newValue) }
    }

    public var applicationIcon: String {
        get { borrowedString(adw_about_dialog_get_application_icon(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_application_icon(pointer.cast(), newValue) }
    }

    public var version: String {
        get { borrowedString(adw_about_dialog_get_version(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_version(pointer.cast(), newValue) }
    }

    public var developerName: String {
        get { borrowedString(adw_about_dialog_get_developer_name(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_developer_name(pointer.cast(), newValue) }
    }

    public var comments: String {
        get { borrowedString(adw_about_dialog_get_comments(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_comments(pointer.cast(), newValue) }
    }

    public var website: String {
        get { borrowedString(adw_about_dialog_get_website(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_website(pointer.cast(), newValue) }
    }

    public var issueURL: String {
        get { borrowedString(adw_about_dialog_get_issue_url(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_issue_url(pointer.cast(), newValue) }
    }

    public var copyright: String {
        get { borrowedString(adw_about_dialog_get_copyright(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_copyright(pointer.cast(), newValue) }
    }

    public var debugInfo: String {
        get { borrowedString(adw_about_dialog_get_debug_info(pointer.cast())) ?? "" }
        set { adw_about_dialog_set_debug_info(pointer.cast(), newValue) }
    }

    /// The license by SPDX-like name (`.mit`, `.gpl30`…); see `GtkLicense`.
    public func setLicenseMIT() { adw_about_dialog_set_license_type(pointer.cast(), GTK_LICENSE_MIT_X11) }

    public func addLink(title: String, url: String) { adw_about_dialog_add_link(pointer.cast(), title, url) }

    /// A legal section for a third-party component (`license` is free text).
    public func addLegalSection(title: String, copyright: String?, license: String) {
        adw_about_dialog_add_legal_section(pointer.cast(), title, copyright, GTK_LICENSE_CUSTOM, license)
    }

    public func addAcknowledgementSection(name: String?, people: [String]) {
        withCStringArray(people) { adw_about_dialog_add_acknowledgement_section(pointer.cast(), name, UnsafeMutablePointer(mutating: $0)) }
    }
}

/// An `AdwShortcutsDialog`: sections of titled accelerators.
@MainActor
public final class ShortcutsDialog: Dialog {
    public init() { super.init(dialogPointer: rawPtr(adw_shortcuts_dialog_new())!) }

    /// Adds a section of (title, GTK accelerator such as `<Control>c`) items.
    public func addSection(title: String?, items: [(title: String, accelerator: String)]) {
        let section = adw_shortcuts_section_new(title)!
        for item in items {
            adw_shortcuts_section_add(section, adw_shortcuts_item_new(item.title, item.accelerator)) // takes ownership
        }
        adw_shortcuts_dialog_add(pointer.cast(), section) // takes ownership
    }
}
