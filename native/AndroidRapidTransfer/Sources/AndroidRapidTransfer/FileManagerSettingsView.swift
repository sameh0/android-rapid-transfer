import AndroidRapidTransferCore
import SwiftUI

struct FileManagerSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show hidden files on This Mac", isOn: $settings.localShowsHiddenFiles)
                Toggle("Show hidden files on the phone", isOn: $settings.deviceShowsHiddenFiles)
            } header: {
                SettingsSectionHeader(
                    title: "Hidden Files",
                    systemImage: showsAnyHiddenFiles ? "eye.fill" : "eye.slash.fill",
                    trigger: showsAnyHiddenFiles
                )
            }

            Section {
                Toggle("Show folders first", isOn: $settings.showDirectoriesFirst)
            } header: {
                SettingsSectionHeader(
                    title: "Sorting",
                    systemImage: "arrow.up.arrow.down",
                    trigger: settings.showDirectoriesFirst
                )
            }

            Section {
                viewModePicker("This Mac", selection: $settings.localViewMode)
                viewModePicker("Phone", selection: $settings.deviceViewMode)
            } header: {
                SettingsSectionHeader(
                    title: "Default View",
                    systemImage: "square.grid.2x2",
                    trigger: [settings.localViewMode, settings.deviceViewMode]
                )
            }

            Section {
                Toggle("When copying to this Mac", isOn: $settings.preprocessFilesBeforeDownload)
                Toggle("When copying to the phone", isOn: $settings.preprocessFilesBeforeUpload)
            } header: {
                SettingsSectionHeader(
                    title: "Overall Progress",
                    systemImage: "gauge.with.dots.needle.67percent",
                    trigger: [settings.preprocessFilesBeforeDownload, settings.preprocessFilesBeforeUpload]
                )
            } footer: {
                Text("Counts the files before a copy starts, so the copy panel can show overall progress. Counting large folders can take from a few seconds to a few minutes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("When a file already exists", selection: $settings.fileConflictPolicy) {
                    Text("Ask for every file").tag(FileConflictPolicy.askEveryFile)
                    Text("Ask once per session").tag(FileConflictPolicy.askEverySession)
                    Text("Always skip").tag(FileConflictPolicy.alwaysSkip)
                    Text("Always overwrite").tag(FileConflictPolicy.alwaysOverwrite)
                }
            } header: {
                SettingsSectionHeader(
                    title: "File Conflicts",
                    systemImage: "doc.on.doc",
                    trigger: settings.fileConflictPolicy
                )
            }

            Section {
                Toggle("Show status bars", isOn: $settings.enableStatusBar)
            } header: {
                SettingsSectionHeader(
                    title: "Status",
                    systemImage: "info.circle",
                    trigger: settings.enableStatusBar
                )
            } footer: {
                Text("The item count and free space under each pane.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var showsAnyHiddenFiles: Bool {
        settings.localShowsHiddenFiles || settings.deviceShowsHiddenFiles
    }

    private func viewModePicker(_ title: LocalizedStringKey, selection: Binding<BrowserViewMode>) -> some View {
        Picker(title, selection: selection) {
            Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
            Label("Grid", systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
        }
        .pickerStyle(.segmented)
    }
}
