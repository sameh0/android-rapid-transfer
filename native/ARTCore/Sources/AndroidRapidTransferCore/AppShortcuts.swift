public enum AppShortcuts {
    public static let newFolder = AppShortcut(
        id: .newFolder,
        title: "New Folder",
        key: .character("n"),
        modifiers: .command,
        scope: .app
    )
    public static let refresh = AppShortcut(
        id: .refresh,
        title: "Refresh",
        key: .character("r"),
        modifiers: .command,
        scope: .app
    )

    /// Copy to Queue: appends to the same queue ⌘C replaces.
    public static let addToCopyQueue = AppShortcut(
        id: .addToCopyQueue,
        title: "Copy Selection to Queue",
        key: .character("c"),
        modifiers: [.command, .shift],
        scope: .app
    )
    /// Browser-scoped: in text fields ⌘C and ⌘V keep their text meaning.
    public static let copySelection = AppShortcut(
        id: .copySelection,
        title: "Copy Selection",
        key: .character("c"),
        modifiers: .command,
        scope: .browser
    )
    public static let pasteQueue = AppShortcut(
        id: .pasteQueue,
        title: "Paste Copied Items into This Pane",
        key: .character("v"),
        modifiers: .command,
        scope: .browser
    )
    public static let switchPane = AppShortcut(
        id: .switchPane,
        title: "Switch Explorer Pane",
        key: .character("1"),
        modifiers: .command,
        scope: .app
    )
    public static let goUp = AppShortcut(
        id: .goUp,
        title: "Go to Parent Folder",
        key: .character("b"),
        modifiers: .command,
        scope: .browser
    )
    public static let rename = AppShortcut(
        id: .rename,
        title: "Rename Selection",
        key: .character("d"),
        modifiers: .command,
        scope: .browser
    )
    public static let selectAll = AppShortcut(
        id: .selectAll,
        title: "Select All",
        key: .character("a"),
        modifiers: .command,
        scope: .browser
    )
    public static let deleteSelection = AppShortcut(
        id: .deleteSelection,
        title: "Delete Selection",
        key: .delete,
        scope: .browser
    )
    public static let openSelection = AppShortcut(
        id: .openSelection,
        title: "Open Selection",
        key: .return,
        scope: .browser
    )
    public static let clearSelection = AppShortcut(
        id: .clearSelection,
        title: "Clear Selection",
        key: .escape,
        scope: .browser
    )
    public static let previousListItem = AppShortcut(
        id: .previousListItem,
        title: "Previous Item in List View",
        key: .upArrow,
        scope: .browser
    )
    public static let nextListItem = AppShortcut(
        id: .nextListItem,
        title: "Next Item in List View",
        key: .downArrow,
        scope: .browser
    )
    public static let previousGridItem = AppShortcut(
        id: .previousGridItem,
        title: "Previous Item in Grid View",
        key: .leftArrow,
        scope: .browser
    )
    public static let nextGridItem = AppShortcut(
        id: .nextGridItem,
        title: "Next Item in Grid View",
        key: .rightArrow,
        scope: .browser
    )
    public static let extendToPreviousListItem = AppShortcut(
        id: .extendToPreviousListItem,
        title: "Extend Selection Up in List View",
        key: .upArrow,
        modifiers: .shift,
        scope: .browser
    )
    public static let extendToNextListItem = AppShortcut(
        id: .extendToNextListItem,
        title: "Extend Selection Down in List View",
        key: .downArrow,
        modifiers: .shift,
        scope: .browser
    )
    public static let extendToPreviousGridItem = AppShortcut(
        id: .extendToPreviousGridItem,
        title: "Extend Selection Left in Grid View",
        key: .leftArrow,
        modifiers: .shift,
        scope: .browser
    )
    public static let extendToNextGridItem = AppShortcut(
        id: .extendToNextGridItem,
        title: "Extend Selection Right in Grid View",
        key: .rightArrow,
        modifiers: .shift,
        scope: .browser
    )

    public static let menuShortcuts = [newFolder, refresh, addToCopyQueue, switchPane]
    public static let browserShortcuts = [
        copySelection,
        pasteQueue,
        goUp,
        rename,
        selectAll,
        deleteSelection,
        openSelection,
        clearSelection,
        previousListItem,
        nextListItem,
        previousGridItem,
        nextGridItem,
        extendToPreviousListItem,
        extendToNextListItem,
        extendToPreviousGridItem,
        extendToNextGridItem
    ]

    public static let registered = menuShortcuts + browserShortcuts
    public static let helpListing = registered
}
