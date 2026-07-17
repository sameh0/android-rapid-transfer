import AndroidRapidTransferCore
import SwiftUI

struct SettingsView: View {
    let settings: AppSettings
    let updater: AppUpdater

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings, updater: updater)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            FileManagerSettingsView(settings: settings)
                .tabItem {
                    Label("File Manager", systemImage: "folder")
                }
        }
        .frame(width: 560, height: 540)
        .onExitCommand(perform: closeWindow)
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.performClose(nil)
    }
}
