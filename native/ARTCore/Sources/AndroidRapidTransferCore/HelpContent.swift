import Foundation

/// One titled block of help text: explanatory paragraphs, then optional
/// numbered steps.
public struct HelpSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let paragraphs: [String]
    public let steps: [String]

    public init(id: String, title: String, paragraphs: [String] = [], steps: [String] = []) {
        self.id = id
        self.title = title
        self.paragraphs = paragraphs
        self.steps = steps
    }
}

/// A troubleshooting topic in the Help window.
public struct HelpTopic: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let summary: String
    public let sections: [HelpSection]
}

/// Help and troubleshooting copy, written for this app.
///
/// Every user-visible string goes through `String(localized:)` so a future
/// String Catalog can extract it, and the app name is always interpolated from
/// ``AppIdentity`` rather than spelled out.
public enum HelpContent {
    /// The steps for getting a phone recognised. Shared by the connection
    /// onboarding page and the "Phone isn't detected" topic so they cannot drift.
    public static func connectionSteps(appName: String = AppIdentity.name) -> [String] {
        [
            String(localized: "Connect the phone with a USB cable that carries data. Some cables only charge — if nothing happens, try another cable or a different port, and avoid unpowered hubs."),
            String(localized: "Unlock the phone and keep it unlocked while it connects."),
            String(localized: "Open the phone's USB notification (usually “Charging this device via USB”) and choose File transfer."),
            String(localized: "If the phone asks “Allow access to phone data?”, tap Allow."),
            String(localized: "Still nothing? Unplug the cable, wait a few seconds, plug it back in, then click Retry in \(appName).")
        ]
    }

    public static func topics(appName: String = AppIdentity.name) -> [HelpTopic] {
        #if os(Linux)
        return linuxTopics(appName: appName)
        #else
        return [
            notDetected(appName: appName),
            allowAccess(appName: appName),
            interferingApps(appName: appName),
            connectionProblems(appName: appName),
            macPermissions(appName: appName)
        ]
        #endif
    }

    private static func notDetected(appName: String) -> HelpTopic {
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
                    title: String(localized: "Another app may have the phone"),
                    paragraphs: [
                        String(localized: "Only one app on a Mac can talk to a phone over MTP at a time. If another app grabbed it first, \(appName) can't connect until that app lets go. See “Apps that block the connection”.")
                    ]
                )
            ]
        )
    }

    private static func allowAccess(appName: String) -> HelpTopic {
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
                        String(localized: "If it reappears every few seconds, something on the Mac is connecting and disconnecting repeatedly — usually another app. Quit the apps listed under “Apps that block the connection”."),
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

    private static func interferingApps(appName: String) -> HelpTopic {
        HelpTopic(
            id: "interfering-apps",
            title: String(localized: "Apps that block the connection"),
            systemImage: "exclamationmark.triangle",
            summary: String(localized: "Quit these before connecting your phone."),
            sections: [
                HelpSection(
                    id: "why",
                    title: String(localized: "Why other apps matter"),
                    paragraphs: [
                        String(localized: "MTP lets only one app use a phone at a time. The apps below can open automatically when a phone is connected and take it before \(appName) does."),
                        String(localized: "The top of this window lists the ones that are running right now, with a button to quit each.")
                    ]
                ),
                HelpSection(
                    id: "android-file-transfer",
                    title: String(localized: "Android File Transfer"),
                    paragraphs: [
                        String(localized: "It opens itself whenever a phone connects. Quit it with ⌘Q, and remove it in System Settings > General > Login Items. If you don't use it, move it to the Trash.")
                    ]
                ),
                HelpSection(
                    id: "google-drive",
                    title: String(localized: "Google Drive"),
                    paragraphs: [
                        String(localized: "Its photo and device backup can claim a connected phone. Quit it from its menu bar icon while you copy files.")
                    ]
                ),
                HelpSection(
                    id: "dropbox-onedrive",
                    title: String(localized: "Dropbox and OneDrive"),
                    paragraphs: [
                        String(localized: "Camera upload can grab the phone as soon as it connects. Turn camera upload off, or quit the app while you copy files.")
                    ]
                ),
                HelpSection(
                    id: "image-capture",
                    title: String(localized: "Image Capture, Preview and Photos"),
                    paragraphs: [
                        String(localized: "macOS can open these automatically for a connected phone. In Image Capture, select the phone and set “Connecting this device opens” to “No application”.")
                    ]
                ),
                HelpSection(
                    id: "smart-switch",
                    title: String(localized: "Samsung Smart Switch"),
                    paragraphs: [
                        String(localized: "Smart Switch installs components that take over Samsung phones. Quit it; if the phone still isn't detected, uninstall Smart Switch with Samsung's uninstaller and restart the Mac.")
                    ]
                )
            ]
        )
    }

    private static func connectionProblems(appName: String) -> HelpTopic {
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
                        String(localized: "If the connection drops, unlock the phone, choose File transfer again, and use File > Resume Copies… to finish an interrupted copy.")
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

    private static func macPermissions(appName: String) -> HelpTopic {
        HelpTopic(
            id: "mac-permissions",
            title: String(localized: "macOS permissions"),
            systemImage: "lock.shield",
            summary: String(localized: "When folders on this Mac can't be opened."),
            sections: [
                HelpSection(
                    id: "files-and-folders",
                    title: String(localized: "Desktop, Documents or Downloads can't be opened"),
                    paragraphs: [
                        String(localized: "macOS asks before an app reads these folders. If you declined, they appear empty or report “permission denied”.")
                    ],
                    steps: [
                        String(localized: "Open System Settings > Privacy & Security > Files & Folders."),
                        String(localized: "Find \(appName) and turn on the folders you want to use."),
                        String(localized: "For USB drives and memory cards, also turn on Removable Volumes.")
                    ]
                ),
                HelpSection(
                    id: "full-disk-access",
                    title: String(localized: "Other protected locations"),
                    paragraphs: [
                        String(localized: "Some locations are only readable with Full Disk Access.")
                    ],
                    steps: [
                        String(localized: "Open System Settings > Privacy & Security > Full Disk Access."),
                        String(localized: "Click +, choose \(appName) in Applications, and turn it on."),
                        String(localized: "Quit \(appName) and open it again so the change takes effect.")
                    ]
                )
            ]
        )
    }
}

/// The privacy statement. Every claim here must stay true of the code: if a
/// feature starts sending data anywhere, add a section saying so.
public enum PrivacyContent {
    public static func sections(
        appName: String = AppIdentity.name,
        bugReportContents: [BugReportItem] = BugReportGenerator.contents()
    ) -> [HelpSection] {
        #if os(Linux)
        return linuxSections(appName: appName, bugReportContents: bugReportContents)
        #else
        return [
            HelpSection(
                id: "no-tracking",
                title: String(localized: "No analytics or tracking"),
                paragraphs: [
                    String(localized: "\(appName) doesn't collect usage data, send analytics or crash reports, or track you. Your files move only between this Mac and your phone, directly over the USB cable.")
                ]
            ),
            HelpSection(
                id: "update-checks",
                title: String(localized: "Update checks"),
                paragraphs: [
                    String(localized: "While automatic update checks are on (Settings > Updates), \(appName) downloads a small list of available versions from GitHub about once a day, and again when you choose Check for Updates…. The request identifies only \(appName) and its version; no system profile, device information or file names are sent. GitHub sees the request as it would any web visit, and its privacy policy applies. Turn automatic checks off to stop these requests.")
                ]
            ),
            HelpSection(
                id: "stored-locally",
                title: String(localized: "What stays on this Mac"),
                paragraphs: [
                    String(localized: "\(appName) keeps a few things in your Library > Application Support folder, and never sends them anywhere:")
                ],
                steps: [
                    String(localized: "Your settings, such as view options and theme."),
                    String(localized: "Saved batch copies, so an interrupted copy can be resumed."),
                    String(localized: "A marker that notices when \(appName) didn't quit normally, so it can offer to help you report the problem.")
                ]
            ),
            HelpSection(
                id: "bug-reports",
                title: String(localized: "Bug reports"),
                paragraphs: [
                    String(localized: "A bug report is created only when you choose Help > Report a Bug…, and \(appName) lists what it will contain before collecting anything. It is saved as a zip file on your Desktop and is never uploaded automatically: \(appName) opens a new-issue page in your browser, and you decide whether to attach the file."),
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
        #endif
    }
}
