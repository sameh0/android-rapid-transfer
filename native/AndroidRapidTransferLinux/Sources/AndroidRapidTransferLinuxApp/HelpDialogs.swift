import ARTGtk
import AndroidRapidTransferCore
import Foundation

/// The Keyboard Shortcuts dialog, from Core's shortcut list with ⌘ as Ctrl,
/// plus the GNOME-style alternatives the Linux app also accepts.
@MainActor
enum ShortcutsHelp {
    static func sections() -> [(title: String, items: [(title: String, accelerator: String)])] {
        var browser: [(String, String)] = []
        var app: [(String, String)] = []
        for group in ShortcutHelp.groups() {
            for shortcut in group.shortcuts {
                var accelerator = shortcut.gtkAccelerator
                switch shortcut.id {
                case .rename: accelerator = "F2 <Control>d"
                case .goUp: accelerator = "<Alt>Up <Control>b"
                case .refresh: accelerator = "<Control>r F5"
                case .deleteSelection: accelerator = "Delete"
                case .switchPane: accelerator = "<Control>1 F6"
                default: break
                }
                let title = shortcut.title.replacingOccurrences(of: "Explorer Pane", with: "Pane")
                if group.scope == .app { app.append((title, accelerator)) } else { browser.append((title, accelerator)) }
            }
        }
        browser.append(("Back", "<Alt>Left BackSpace"))
        browser.append(("Forward", "<Alt>Right"))
        browser.append(("Show Hidden Files", "<Control>h"))
        browser.append(("Filter This Folder", "<Control>f"))
        browser.append(("Properties", "<Control>i"))
        browser.append(("Context Menu", "<Shift>F10 Menu"))
        app.append(("Show This Computer", "F9"))
        app.append(("Preferences", "<Control>comma"))
        app.append(("Keyboard Shortcuts", "<Control>question"))
        app.append(("Troubleshooting & FAQ", "F1"))
        app.append(("Quit", "<Control>q"))
        return [("General", app), ("File Browser", browser)]
    }

    static func makeDialog() -> ShortcutsDialog {
        let dialog = ShortcutsDialog()
        for section in sections() {
            dialog.addSection(title: section.title, items: section.items)
        }
        return dialog
    }
}

/// Troubleshooting, privacy and About, from Core's help content.
@MainActor
enum HelpDialogs {
    static func troubleshooting() -> Dialog {
        let page = PreferencesPage(title: "Troubleshooting")
        for topic in HelpContent.topics() {
            let group = PreferencesGroup(title: topic.title, description: topic.summary)
            for section in topic.sections {
                let row = ExpanderRow(title: section.title)
                row.addRow(textRow(section))
                group.add(row)
            }
            page.add(group)
        }
        return wrap(page, title: "Troubleshooting & FAQ", width: 640, height: 720)
    }

    static func privacy() -> Dialog {
        let page = PreferencesPage(title: "Privacy")
        for section in PrivacyContent.sections() {
            let group = PreferencesGroup(title: section.title)
            group.add(textRow(section).css("card"))
            page.add(group)
        }
        return wrap(page, title: "Privacy", width: 580, height: 620)
    }

    static func about() -> Dialog {
        let info = AboutInfo.current
        let about = AboutDialog()
        about.applicationName = info.name
        about.applicationIcon = IconTheme.has(AppIdentity.bundleIdentifier) ? AppIdentity.bundleIdentifier : "phone-symbolic"
        about.version = info.version
        about.developerName = AppIdentity.copyrightHolder
        about.copyright = info.copyright
        about.comments = "Fast file transfer between Android phones and your computer, over USB."
        about.website = AppIdentity.repositoryURL.absoluteString
        about.issueURL = AppIdentity.issuesURL.absoluteString
        about.setLicenseMIT()
        about.addLink(title: "Troubleshooting &amp; FAQ", url: AppIdentity.repositoryURL.absoluteString)
        about.addLegalSection(
            title: "GTK and libadwaita",
            copyright: "The GTK Team and the GNOME Project",
            license: "Used as system libraries under the GNU Lesser General Public License, version 2.1 or later."
        )
        about.debugInfo = BugReportEnvironment.describe(bundleURL: Bundle.main.bundleURL, processInfo: .processInfo)
        return about
    }

    /// Paragraphs, then numbered steps.
    static func textRow(_ section: HelpSection) -> Widget {
        let box = Box(.vertical, spacing: 8).margins(top: 10, bottom: 12, start: 14, end: 14)
        for paragraph in section.paragraphs {
            let label = Label(paragraph).align(h: .start)
            label.wraps = true
            label.xalign = 0
            label.isSelectable = true
            if paragraph.hasPrefix("echo ") { label.css("monospace", "caption") }
            box.append(label)
        }
        for (index, step) in section.steps.enumerated() {
            let number = Label("\(index + 1).").css("dim-label", "numeric").align(h: .start, v: .start)
            let text = Label(step).align(h: .start).expand(h: true)
            text.wraps = true
            text.xalign = 0
            text.isSelectable = true
            box.append(Box(.horizontal, spacing: 8, [number, text]))
        }
        return box
    }

    static func wrap(_ page: PreferencesPage, title: String, width: Int32, height: Int32) -> Dialog {
        let dialog = Dialog(title: title, width: width, height: height)
        let toolbar = ToolbarView()
        toolbar.addTopBar(HeaderBar())
        toolbar.content = page
        dialog.child = toolbar
        return dialog
    }
}

/// The first-run welcome, and the "Connecting Your Phone" help.
@MainActor
final class OnboardingDialog {
    let dialog = Dialog(title: "Welcome", width: 540, height: 700)

    init(startAtConnection: Bool) {
        let toolbar = ToolbarView()
        toolbar.addTopBar(HeaderBar())
        let page = StatusPage(
            title: startAtConnection ? "Connect your phone" : "Welcome to \(AppIdentity.name)",
            description: startAtConnection
                ? "Follow these steps so your computer can see the phone’s files."
                : "Copy photos, videos and files between your Android phone and this computer, quickly and directly over USB.",
            iconName: IconTheme.has(AppIdentity.bundleIdentifier) && !startAtConnection ? AppIdentity.bundleIdentifier : "phone-symbolic"
        )
        let steps = ListBox()
        for (index, step) in HelpContent.connectionSteps().enumerated() {
            let number = Label("\(index + 1)").css("step-number").align(v: .start)
            let text = Label(step).align(h: .start).expand(h: true)
            text.wraps = true
            text.xalign = 0
            steps.append(Box(.horizontal, spacing: 12, [number, text]).css("onboarding-step"))
        }
        let done = Button(startAtConnection ? "Done" : "Get Started").css("pill", "suggested-action").align(h: .center)
        done.onClicked { [weak dialog] in dialog?.close() }
        page.child = Box(.vertical, spacing: 24, [steps, done])
        toolbar.content = page
        dialog.title = startAtConnection ? "Connecting Your Phone" : "Welcome"
        dialog.child = toolbar
        dialog.setDefaultWidget(done)
    }
}
