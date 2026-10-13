#if os(Linux)
import Foundation

/// The Linux help: the same topics as on macOS where the advice is the same,
/// with the desktop's own programs (GNOME Files, KDE's device service) in
/// place of the Mac apps that grab phones, and Linux device permissions in
/// place of macOS privacy settings.
extension HelpContent {
    static func linuxTopics(appName: String) -> [HelpTopic] {
        [
            linuxNotDetected(appName: appName),
            linuxAllowAccess(appName: appName),
            linuxInterferingApps(appName: appName),
            linuxConnectionProblems(appName: appName),
            linuxPermissions(appName: appName)
        ]
    }

    /// A shell command that installs the packaged udev rules
    /// (``LinuxUdevRules``) and reloads udev.
    public static var linuxUdevInstallCommand: String {
        LinuxUdevRules.installCommand
    }

    private static func linuxNotDetected(appName: String) -> HelpTopic {
        HelpTopic(
            id: "not-detected",
            title: String(localized: "Phone isn't detected"),
            systemImage: "cable.connector",
            summary: String(localized: "The basics that fix most connection problems."),
            sections: [
                HelpSection(
                    id: "basics",
                    title: String(localized: "Check the basics"),
                    steps: connectionSteps(appName: appName)
                ),
                HelpSection(
                    id: "already-file-transfer",
                    title: String(localized: "Already on File transfer but still not detected"),
                    paragraphs: [
                        String(localized: "Android sometimes keeps showing File transfer after the connection has actually stopped. Resetting the USB mode usually brings it back.")
                    ],
                    steps: [
                        String(localized: "On the phone, open the USB notification and choose Charging only."),
                        String(localized: "Wait a few seconds, then choose File transfer again."),
                        String(localized: "Click Retry in \(appName)."),
                        String(localized: "If it still isn't found, restart the phone and try once more.")
                    ]
                ),
                HelpSection(
                    id: "other-apps",
                    title: String(localized: "Another program may have the phone"),
                    paragraphs: [
                        String(localized: "Only one program on a computer can talk to a phone over MTP at a time. If the file manager or another program opened it first, \(appName) can't connect until it lets go. \(appName) names the program when this happens. See “Programs that block the connection”.")
                    ]
                )
            ]
        )
    }

    private static func linuxAllowAccess(appName: String) -> HelpTopic {
        HelpTopic(
            id: "allow-access",
            title: String(localized: "“Allow access to phone data” prompt"),
            systemImage: "hand.raised",
            summary: String(localized: "Why Android asks, and what to do when it keeps asking."),
            sections: [
                HelpSection(
                    id: "why",
                    title: String(localized: "Why the phone asks"),
                    paragraphs: [
                        String(localized: "Android asks for permission each time a computer connects in File transfer mode. Until you tap Allow, \(appName) can see the phone but not its files, so storage looks empty or missing.")
                    ]
                ),
                HelpSection(
                    id: "keeps-asking",
                    title: String(localized: "If the prompt keeps coming back"),
                    steps: [
                        String(localized: "Unlock the phone before plugging it in, and tap Allow rather than dismissing the prompt."),
                        String(localized: "If it reappears every few seconds, another program on the computer is connecting and disconnecting repeatedly — usually the file manager. See “Programs that block the connection”."),
                        String(localized: "Reset the USB mode: choose Charging only, then File transfer again.")
                    ]
                ),
                HelpSection(
                    id: "empty-storage",
                    title: String(localized: "Storage is empty or missing"),
                    paragraphs: [
                        String(localized: "Approve the prompt on the phone, then click Refresh. Some phones only show an SD card while they are unlocked.")
                    ]
                )
            ]
        )
    }

    private static func linuxInterferingApps(appName: String) -> HelpTopic {
        HelpTopic(
            id: "interfering-apps",
            title: String(localized: "Programs that block the connection"),
            systemImage: "exclamationmark.triangle",
            summary: String(localized: "What else on the desktop can hold on to a phone."),
            sections: [
                HelpSection(
                    id: "why",
                    title: String(localized: "Why other programs matter"),
                    paragraphs: [
                        String(localized: "MTP lets only one program use a phone at a time. The desktop can open a phone by itself as soon as it is plugged in, and then \(appName) reports that the phone is busy and names the program holding it.")
                    ]
                ),
                HelpSection(
                    id: "gnome-files",
                    title: String(localized: "Files (GNOME) and other GVFS file managers"),
                    paragraphs: [
                        String(localized: "GNOME's file manager, and others built on GVFS such as Nemo, Caja and Thunar, mount a phone automatically and keep it open while it is mounted. Eject the phone in the file manager's sidebar, then click Try Again in \(appName). \(appName) can also release it for you when you click “Release the Phone”.")
                    ]
                ),
                HelpSection(
                    id: "kde",
                    title: String(localized: "KDE Plasma"),
                    paragraphs: [
                        String(localized: "KDE's device service (kiod) opens phones for Dolphin and does not let go of them while it runs. Close Dolphin's phone view; if the phone stays busy, stop the service with “kquitapp6 kiod6” (it starts again when needed), then click Try Again.")
                    ]
                ),
                HelpSection(
                    id: "photo-apps",
                    title: String(localized: "Photo importers"),
                    paragraphs: [
                        String(localized: "Shotwell, digiKam, darktable and gThumb can open a phone to import photos, and gphoto2-based tools claim phones that are in PTP (camera) mode. Close them, and choose File transfer rather than PTP on the phone.")
                    ]
                ),
                HelpSection(
                    id: "other-transfer-tools",
                    title: String(localized: "Other transfer tools"),
                    paragraphs: [
                        String(localized: "Other MTP programs, such as Android File Transfer for Linux, gMTP, jmtpfs or simple-mtpfs mounts, hold the phone while they run. Quit them or unmount the phone first.")
                    ]
                )
            ]
        )
    }

    private static func linuxConnectionProblems(appName: String) -> HelpTopic {
        HelpTopic(
            id: "connection-problems",
            title: String(localized: "Connection and copy problems"),
            systemImage: "arrow.left.arrow.right",
            summary: String(localized: "Stuck refreshes, dropped connections and missing storage."),
            sections: [
                HelpSection(
                    id: "stuck-refresh",
                    title: String(localized: "Refresh or loading seems stuck"),
                    paragraphs: [
                        String(localized: "The phone handles one request at a time over USB, so a folder with thousands of files can take a few seconds to list. If nothing changes for a long time, unplug the phone, wait a few seconds, plug it back in, and click Retry.")
                    ]
                ),
                HelpSection(
                    id: "phone-sleeps",
                    title: String(localized: "The phone locks or sleeps during a copy"),
                    paragraphs: [
                        String(localized: "Many phones leave File transfer mode when they lock or go to sleep, which ends the connection mid-copy. Keep the screen on for long copies — raise the screen timeout, or turn on Stay awake in Developer options."),
                        String(localized: "If the connection drops, unlock the phone, choose File transfer again, and use Resume Copies… in the main menu to finish an interrupted copy.")
                    ]
                ),
                HelpSection(
                    id: "storage-missing",
                    title: String(localized: "Internal storage or SD card is missing"),
                    paragraphs: [
                        String(localized: "Make sure you tapped Allow on the phone, then pick the storage from the storage menu above the phone’s files. Some phones only expose an SD card while unlocked.")
                    ]
                ),
                HelpSection(
                    id: "multiple-devices",
                    title: String(localized: "More than one phone is connected"),
                    paragraphs: [
                        String(localized: "\(appName) works with one phone at a time. Disconnect the others, then click Retry.")
                    ]
                )
            ]
        )
    }

    private static func linuxPermissions(appName: String) -> HelpTopic {
        HelpTopic(
            id: "linux-permissions",
            title: String(localized: "USB permissions"),
            systemImage: "lock.shield",
            summary: String(localized: "When Linux doesn't let \(appName) open the phone."),
            sections: [
                HelpSection(
                    id: "uaccess",
                    title: String(localized: "Why access can be denied"),
                    paragraphs: [
                        String(localized: "Linux gives the person logged in at the computer access to phones in File transfer mode through a udev rule that systemd ships. Some systems, and phones that describe themselves unusually, are not covered, and then only the administrator may open the phone."),
                        String(localized: "\(appName) says so when this happens and shows the command that fixes it.")
                    ]
                ),
                HelpSection(
                    id: "install-rule",
                    title: String(localized: "Allow access to phones"),
                    paragraphs: [
                        String(localized: "Run this command in a terminal. It asks for your password, installs the udev rules the app's packages use, and reloads udev:"),
                        linuxUdevInstallCommand
                    ],
                    steps: [
                        String(localized: "Unplug the phone and plug it back in."),
                        String(localized: "Choose File transfer on the phone, then click Try Again in \(appName).")
                    ]
                ),
                HelpSection(
                    id: "sandbox",
                    title: String(localized: "Remote and sandboxed sessions"),
                    paragraphs: [
                        String(localized: "Access is granted only to the session at the computer's own screen. Over SSH, or in a container or sandbox without USB access, \(appName) cannot open the phone.")
                    ]
                )
            ]
        )
    }
}

extension PrivacyContent {
    static func linuxSections(appName: String, bugReportContents: [BugReportItem]) -> [HelpSection] {
        [
            HelpSection(
                id: "no-tracking",
                title: String(localized: "No analytics or tracking"),
                paragraphs: [
                    String(localized: "\(appName) doesn't collect usage data, send analytics or crash reports, or track you. Your files move only between this computer and your phone, directly over the USB cable. It makes no network requests of its own.")
                ]
            ),
            HelpSection(
                id: "stored-locally",
                title: String(localized: "What stays on this computer"),
                paragraphs: [
                    String(localized: "\(appName) keeps a few things in your home folder, and never sends them anywhere:")
                ],
                steps: [
                    String(localized: "Your settings, such as view options and theme, in ~/.config."),
                    String(localized: "Saved batch copies, so an interrupted copy can be resumed, in ~/.local/share."),
                    String(localized: "A marker that notices when \(appName) didn't quit normally, so it can offer to help you report the problem, in ~/.local/state.")
                ]
            ),
            HelpSection(
                id: "bug-reports",
                title: String(localized: "Bug reports"),
                paragraphs: [
                    String(localized: "A bug report is created only when you choose Report a Bug… in the main menu, and \(appName) lists what it will contain before collecting anything. It is saved as a zip file where you choose and is never uploaded automatically: \(appName) opens a new-issue page in your browser, and you decide whether to attach the file."),
                    String(localized: "A report contains:")
                ],
                steps: bugReportContents.map { "\($0.fileName) — \($0.description)" }
            ),
            HelpSection(
                id: "links",
                title: String(localized: "Links"),
                paragraphs: [
                    String(localized: "Help and bug-report links open in your web browser, and that website's own privacy policy applies there.")
                ]
            )
        ]
    }
}
#endif
