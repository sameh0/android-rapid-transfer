struct BrowserCopyAction {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    /// Shown as help text so a greyed-out action explains itself instead of
    /// leaving the user guessing why it will not fire.
    var disabledReason: String?
    let perform: () -> Void
}
