import AndroidRapidTransferCore
import SwiftUI

struct AndroidRapidTransferCommands: Commands {
    let settings: AppSettings
    let focusCoordinator: PaneFocusCoordinator
    let onboarding: OnboardingCoordinator
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.name)") { openWindow(id: AppWindowID.about) }
            Button("Acknowledgements…") { openWindow(id: AppWindowID.acknowledgements) }
            // Only builds that can actually update offer the command.
            if updater.isAvailable {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        CommandGroup(replacing: .help) {
            ForEach(HelpMenuItem.allCases, id: \.self) { item in
                Button(item.title) { open(item) }
                if item.isFollowedByDivider {
                    Divider()
                }
            }
            Divider()
            Button("\(AppIdentity.name) on GitHub", action: openWebsite)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Folder", action: createFolder)
                .keyboardShortcut(
                    AppShortcuts.newFolder.keyEquivalent,
                    modifiers: AppShortcuts.newFolder.eventModifiers
                )
                .disabled(browserCommands?.canCreateFolder != true)
        }

        CommandGroup(after: .newItem) {
            Button("Refresh", action: refresh)
                .keyboardShortcut(
                    AppShortcuts.refresh.keyEquivalent,
                    modifiers: AppShortcuts.refresh.eventModifiers
                )
                .disabled(browserCommands?.canRefresh != true)
            Divider()
            Button("Resume Copies…", action: showResumeCopies)
                .help("Review saved batch copies and resume their pending or failed files.")
        }

        // ⌘C and ⌘V stay on the standard Edit ▸ Copy/Paste items, which the
        // focused browser answers through the responder chain; only the
        // append variant needs its own item.
        CommandGroup(after: .pasteboard) {
            Button(AppShortcuts.addToCopyQueue.title, action: addToCopyQueue)
                .keyboardShortcut(
                    AppShortcuts.addToCopyQueue.keyEquivalent,
                    modifiers: AppShortcuts.addToCopyQueue.eventModifiers
                )
                .disabled(browserCommands?.canAddToCopyQueue != true)
                .help(
                    browserCommands?.canAddToCopyQueue == true
                        ? "Add the selected items to the copy queue, then paste them into the other pane."
                        : "Select one or more items first."
                )
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button("List View", systemImage: listViewSystemImage) {
                browserCommands?.setViewMode(.list)
            }
            .disabled(browserCommands == nil)
            Button("Grid View", systemImage: gridViewSystemImage) {
                browserCommands?.setViewMode(.grid)
            }
            .disabled(browserCommands == nil)
            Button(hiddenFilesTitle, action: toggleHiddenFiles)
                .disabled(browserCommands == nil)
            Divider()
            Button("Switch Explorer Pane", action: switchPane)
                .keyboardShortcut(
                    AppShortcuts.switchPane.keyEquivalent,
                    modifiers: AppShortcuts.switchPane.eventModifiers
                )
                .disabled(!settings.showLocalPane)
        }
    }

    private var listViewSystemImage: String {
        browserCommands?.viewMode == .list ? "checkmark" : "list.bullet"
    }

    private var browserCommands: BrowserCommandActions? {
        focusCoordinator.browserCommandActions
    }

    private var gridViewSystemImage: String {
        browserCommands?.viewMode == .grid ? "checkmark" : "square.grid.2x2"
    }

    private var hiddenFilesTitle: String {
        browserCommands?.showsHiddenFiles == true ? "Hide Hidden Files" : "Show Hidden Files"
    }

    private func createFolder() {
        browserCommands?.createFolder()
    }

    private func refresh() {
        browserCommands?.refresh()
    }

    private func addToCopyQueue() {
        browserCommands?.addToCopyQueue()
    }

    private func toggleHiddenFiles() {
        browserCommands?.toggleHiddenFiles()
    }

    private func switchPane() {
        focusCoordinator.switchPane(showLocalPane: settings.showLocalPane)
    }

    private func openWebsite() {
        NSWorkspace.shared.open(AppIdentity.repositoryURL)
    }

    private func open(_ item: HelpMenuItem) {
        switch item.destination {
        case let .window(id):
            openWindow(id: id)
        case .connectionOnboarding:
            onboarding.show(page: .connect)
        case .onboarding:
            onboarding.show()
        }
    }

    private func showResumeCopies() {
        openWindow(id: AppWindowID.resumeCopies)
    }
}
