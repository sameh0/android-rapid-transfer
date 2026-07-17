import AndroidRapidTransferCore
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    let updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $settings.theme.animation(snappy)) {
                    Text("System").tag(AppTheme.system)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                }
                .pickerStyle(.segmented)
            } header: {
                SettingsSectionHeader(title: "Appearance", systemImage: themeSymbol, trigger: settings.theme)
            }

            Section {
                Toggle("Show dual-pane browser", isOn: $settings.showLocalPane.animation(snappy))
                if settings.showLocalPane {
                    Toggle("Place This Mac on the left", isOn: $settings.localPaneOnLeft)
                        .motionTransition(.opacity.combined(with: .move(edge: .top)))
                }
            } header: {
                SettingsSectionHeader(
                    title: "Layout",
                    systemImage: settings.showLocalPane ? "rectangle.split.2x1" : "rectangle",
                    trigger: settings.showLocalPane
                )
            } footer: {
                Text("The phone-first browser works directly with Finder using drag and drop. Turn on the second pane only when you want both locations in one window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically detect USB changes", isOn: $settings.enableUsbHotplug)
            } header: {
                SettingsSectionHeader(title: "Connection", systemImage: "cable.connector.horizontal", trigger: settings.enableUsbHotplug)
            } footer: {
                Text("Finds your phone as soon as it's plugged in, and notices when it's unplugged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            updatesSection

            Section {
                LabeledContent {
                    Button("Privacy Details…") { openWindow(id: AppWindowID.privacy) }
                } label: {
                    Text("No analytics or tracking. Files move only between this Mac and your phone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                SettingsSectionHeader(title: "Privacy", systemImage: "hand.raised.fill")
            }
        }
        .formStyle(.grouped)
    }

    /// For bindings whose changes show or hide rows.
    private var snappy: Animation? {
        MotionPolicy(reduceMotion: reduceMotion).animation(Motion.snappy)
    }

    private var themeSymbol: String {
        switch settings.theme {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        case .system: "circle.lefthalf.filled"
        }
    }

    private var updatesSection: some View {
        let preferences = settings.updatePreferences()
        return Section {
            Toggle(
                "Automatically check for updates",
                isOn: $settings.automaticallyChecksForUpdates.animation(snappy)
            )
            // Background downloads only make sense while checks run.
            Toggle(
                "Automatically download and install updates",
                isOn: $settings.automaticallyDownloadsUpdates
            )
            .disabled(!settings.automaticallyChecksForUpdates)
            Toggle("Include beta releases", isOn: betaBinding(preferences))
                .disabled(preferences.isBetaChannelLocked)
            if preferences.isBetaChannelLocked {
                Text("This is a beta build, so it keeps receiving beta updates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !updater.isAvailable {
                Text("This build can't update itself. Updates are delivered to released builds only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeader(
                title: "Updates",
                systemImage: "arrow.triangle.2.circlepath",
                trigger: settings.automaticallyChecksForUpdates
            )
        }
    }

    /// Shows the effective value, so a beta build displays the switch locked on.
    private func betaBinding(_ preferences: UpdatePreferences) -> Binding<Bool> {
        Binding(
            get: { preferences.receivesBetaUpdates },
            set: { settings.receivesBetaUpdates = $0 }
        )
    }
}
