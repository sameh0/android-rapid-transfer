import ARTGtk
import AndroidRapidTransferCore
import Foundation
#if os(Linux)
import SwiftMTP
#endif

/// The device pane's "not browsing yet" screens: waiting for a phone,
/// connecting, reconnecting, replug, and connection failures — including the
/// Linux-specific ones (another program holds the phone, or the USB device
/// node is not accessible).
@MainActor
final class ConnectionStageView {
    let root: StatusPage
    var onShowConnectionHelp: () -> Void = {}
    var onShowTroubleshooting: () -> Void = {}
    var parentWindow: () -> Window? = { nil }
    private let controller: DeviceConnectionController
    private var shownKey: String?
    private let appName = AppIdentity.name

    init(controller: DeviceConnectionController) {
        self.controller = controller
        root = StatusPage(title: "")
        root.css("connection-stage")
        root.expand(h: true, v: true)
    }

    /// Shows `phase`, rebuilding the content only when the screen changes.
    func show(_ phase: ConnectionPanePhase) {
        let key = Self.key(for: phase)
        guard key != shownKey else { return }
        shownKey = key
        switch phase {
        case .waiting, .connected:
            showWaiting()
        case .detecting:
            showDetecting(reconnect: nil)
        case let .reconnecting(progress):
            showDetecting(reconnect: progress)
        case let .needsReplug(deviceName, message):
            showReplug(deviceName: deviceName, message: message)
        case let .failed(message, retryable):
            switch DeviceAccessProblem(message: message) {
            case let .busy(detail)?:
                showBusy(detail: detail, problem: .busy(detail: detail))
            case let .permissionDenied(detail)?:
                showPermissionDenied(detail: detail)
            case nil:
                showFailure(message: message, retryable: retryable)
            }
        }
        if root.isMapped {
            Animation.spring(on: root, Motion.gentle, property: "opacity", from: 0.4, to: 1).play()
        }
    }

    private static func key(for phase: ConnectionPanePhase) -> String {
        switch phase {
        case .waiting, .connected: "waiting"
        case .detecting: "detecting"
        case let .reconnecting(progress): "reconnecting-\(progress.attempt)-\(progress.isAttempting)"
        case let .needsReplug(name, message): "replug-\(name ?? "")-\(message ?? "")"
        case let .failed(message, retryable): "failed-\(retryable)-\(message)"
        }
    }

    // MARK: - Screens

    private func showWaiting() {
        root.iconName = "phone-symbolic"
        root.title = "Connect your Android phone"
        root.descriptionText = "\(appName) finds your phone as soon as it’s ready."
        let steps = Box(.vertical, spacing: 6).css("connection-steps").align(h: .center)
        let items: [(String, String)] = [
            ("drive-harddisk-usb-symbolic", "Plug your phone into this computer"),
            ("system-lock-screen-symbolic", "Unlock it, and keep it unlocked"),
            ("phone-symbolic", "Choose File transfer if Android asks how to use USB")
        ]
        for (index, item) in items.enumerated() {
            let number = Label("\(index + 1)").css("step-number")
            let icon = Image(iconName: item.0)
            let text = Label(item.1).align(h: .start).expand(h: true)
            text.wraps = true
            steps.append(Box(.horizontal, spacing: 12, [number, icon, text]).css("connection-step"))
        }
        steps.sizeRequest(width: 380)
        let content = Box(.vertical, spacing: 18, [steps, retryButton(prominent: false), helpLinks()])
        root.child = Clamp(content, maximumSize: 460)
    }

    private func showDetecting(reconnect: ConnectionReconnectProgress?) {
        root.iconName = nil
        let spinner = Spinner().sizeRequest(width: 48, height: 48).align(h: .center)
        var children: [Widget] = [spinner]
        if let reconnect {
            root.title = "Reconnecting…"
            root.descriptionText = "The connection dropped. This usually sorts itself out in a moment — keep your phone unlocked."
            let attempt = reconnect.attempt > 0
                ? "Attempt \(reconnect.attempt) of \(reconnect.limit)"
                : "Waiting for the phone…"
            children.append(Label(attempt).css("dim-label", "numeric"))
        } else {
            root.title = "Connecting to your phone…"
            root.descriptionText = "Keep your phone unlocked. If it asks to allow access to phone data, tap Allow."
        }
        root.child = Box(.vertical, spacing: 12, children)
    }

    private func showReplug(deviceName: String?, message: String?) {
        root.iconName = "drive-harddisk-usb-symbolic"
        root.title = "Unplug and reconnect your phone"
        root.descriptionText = message ?? (deviceName.map { "Unplug \($0), then plug it back in to start a fresh connection." }
            ?? "Unplug the phone, then plug it back in to start a fresh connection.")
        var children: [Widget] = []
        if controller.canManuallyRetryReplug { children.append(retryButton(prominent: false)) }
        children.append(helpLinks())
        root.child = Box(.vertical, spacing: 18, children)
    }

    private func showFailure(message: String, retryable: Bool) {
        root.iconName = "dialog-warning-symbolic"
        root.title = "Couldn’t connect to the phone"
        root.descriptionText = "Check that the cable is firmly plugged in and the phone is unlocked, then try again."
        var children: [Widget] = []
        if retryable { children.append(retryButton(prominent: true)) }
        children.append(helpLinks())
        children.append(details(message))
        root.child = Clamp(Box(.vertical, spacing: 18, children), maximumSize: 460)
    }

    // MARK: Busy

    private struct Holder {
        let command: String
        let displayName: String
        let description: String
    }

    private func holders(for problem: DeviceAccessProblem) -> [Holder] {
        #if os(Linux)
        guard let node = problem.deviceNodePath else { return [] }
        // ART_HOLDER_PROC_ROOT points the lookup at a fake /proc (screenshots, tests).
        let procRoot = ProcessInfo.processInfo.environment["ART_HOLDER_PROC_ROOT"] ?? "/proc"
        return USBDeviceHolder.likelyMTPHolders(USBDeviceHolder.find(nodePath: node, procRoot: procRoot)).map {
            Holder(command: $0.command, displayName: $0.displayName, description: $0.description)
        }
        #else
        return []
        #endif
    }

    private func showBusy(detail: String, problem: DeviceAccessProblem) {
        let holders = holders(for: problem)
        let isGVFS = holders.contains { $0.command.hasPrefix("gvfsd") }
        let isKDE = holders.contains { $0.command.hasPrefix("kiod") }
        var seen = Set<String>()
        let names = holders.map(\.displayName).filter { seen.insert($0).inserted }

        root.iconName = "dialog-warning-symbolic"
        root.title = "Another program is using your phone"
        if names.isEmpty {
            root.descriptionText = "Another program has the phone open, so \(appName) can’t connect to it. Only one program can use a phone at a time."
        } else {
            root.descriptionText = "\(names.joined(separator: " and ")) \(names.count == 1 ? "has" : "have") the phone open, so \(appName) can’t connect to it. Only one program can use a phone at a time."
        }

        var children: [Widget] = []
        let explanation = Label().css("dim-label")
        explanation.wraps = true
        explanation.justifyCenter = true
        explanation.maxWidthChars = 52
        let buttons = Box(.horizontal, spacing: 12).align(h: .center)
        if isGVFS {
            explanation.text = "The Files app (and other file managers built on GVFS) opens phones by itself as soon as they are plugged in, and keeps them open while they are mounted. Eject the phone in the Files sidebar, or release it here."
            let release = Button("Release the Phone", iconName: "media-eject-symbolic").css("pill", "suggested-action")
            release.tooltip = "Unmount the phone in the file manager, then connect here"
            let prefix = holders.contains { $0.command == "gvfsd-gphoto2" } ? "gphoto2://" : "mtp://"
            release.onClicked { [weak self, weak release] in
                release?.isSensitive = false
                release?.setContent(label: "Releasing…", iconName: "media-eject-symbolic")
                self?.releaseGVFS(prefix: prefix)
            }
            buttons.append(release)
            buttons.append(tryAgainButton(prominent: false))
        } else if isKDE {
            explanation.text = "KDE’s device service keeps phones open while it runs. Stop it for now with the command below — it starts again when needed — then try again."
            children.append(explanation)
            children.append(commandRow("kquitapp6 kiod6"))
            buttons.append(tryAgainButton(prominent: true))
        } else {
            explanation.text = "Close the program that is using the phone, or unmount the phone in your file manager, then try again."
            buttons.append(tryAgainButton(prominent: true))
        }
        if !isKDE { children.append(explanation) }
        children.append(buttons)
        children.append(helpLinks())
        var detailText = detail
        if !holders.isEmpty {
            detailText += "\n\nHolding the phone: " + holders.map(\.description).joined(separator: ", ")
        }
        children.append(details(detailText))
        root.child = Clamp(Box(.vertical, spacing: 16, children), maximumSize: 520)
    }

    /// Unmounts the file manager's phone mount — only ever on the user's
    /// click — then retries the connection.
    private func releaseGVFS(prefix: String) {
        let controller = controller
        GioMounts.unmount(rootURIPrefix: prefix) { [weak self] errors in
            if !errors.isEmpty {
                self?.shownKey = nil
                let alert = AlertDialog(heading: "Couldn’t release the phone",
                                        body: errors.joined(separator: "\n") + "\n\nEject the phone in the file manager’s sidebar, then click Try Again.")
                alert.addResponse("ok", "OK")
                Task { _ = await alert.choose(parent: self?.parentWindow()) }
            }
            Task { await controller.retry() }
        }
    }

    // MARK: Permission

    private func showPermissionDenied(detail: String) {
        root.iconName = "dialog-password-symbolic"
        root.title = "Linux isn’t letting \(appName) open the phone"
        root.descriptionText = "Your account doesn’t have access to the phone’s USB device. Most desktops grant it automatically, but this system doesn’t for this phone."
        let intro = Label("Run this command in a terminal to allow access to Android phones, then unplug the phone and plug it back in:").css("dim-label")
        intro.wraps = true
        intro.justifyCenter = true
        intro.maxWidthChars = 52
        let buttons = Box(.horizontal, spacing: 12, [tryAgainButton(prominent: true)]).align(h: .center)
        let children: [Widget] = [intro, commandRow(HelpContent.linuxUdevInstallCommand), buttons, helpLinks(), details(detail)]
        root.child = Clamp(Box(.vertical, spacing: 16, children), maximumSize: 560)
    }

    // MARK: - Pieces

    private func retryButton(prominent: Bool) -> Widget {
        let button = Button("Retry", iconName: "view-refresh-symbolic").css("pill")
        if prominent { button.addCSSClass("suggested-action") }
        button.tooltip = "Try connecting to the phone again"
        button.align(h: .center)
        let controller = controller
        button.onClicked { [weak button] in
            if let button { Animation.spring(on: button, Motion.bouncy, property: "opacity", from: 0.5, to: 1).play() }
            Task { await controller.retry() }
        }
        return button
    }

    private func tryAgainButton(prominent: Bool) -> Widget {
        let button = Button("Try Again", iconName: "view-refresh-symbolic").css("pill")
        if prominent { button.addCSSClass("suggested-action") }
        let controller = controller
        button.onClicked { [weak self] in
            self?.shownKey = nil
            Task { await controller.retry() }
        }
        return button
    }

    private func helpLinks() -> Widget {
        let help = Button("Connection Help").css("flat", "link-button")
        help.onClicked { [weak self] in self?.onShowConnectionHelp() }
        let troubleshooting = Button("Troubleshooting").css("flat", "link-button")
        troubleshooting.onClicked { [weak self] in self?.onShowTroubleshooting() }
        return Box(.horizontal, spacing: 12, [help, troubleshooting]).align(h: .center)
    }

    private func commandRow(_ command: String) -> Widget {
        let label = Label(command).css("monospace", "command-text")
        label.isSelectable = true
        label.wraps = true
        label.align(h: .start).expand(h: true)
        let copy = Button(iconName: "edit-copy-symbolic", tooltip: "Copy the command").css("flat")
        copy.onClicked { [weak copy] in
            Clipboard.setText(command)
            copy?.tooltip = "Copied"
            copy?.iconName = "object-select-symbolic"
        }
        return Box(.horizontal, spacing: 8, [label, copy]).css("card", "command-card")
    }

    private func details(_ text: String) -> Widget {
        let label = Label(text).css("caption", "monospace", "dim-label")
        label.wraps = true
        label.isSelectable = true
        label.align(h: .start)
        let copy = Button(iconName: "edit-copy-symbolic", tooltip: "Copy the details, for a bug report").css("flat").align(v: .start)
        copy.onClicked { Clipboard.setText(text) }
        let body = Box(.horizontal, spacing: 6, [label.expand(h: true), copy]).margins(top: 6)
        let revealer = Revealer(body, transition: .slideDown, duration: Motion.Duration.standard)
        let toggle = Button("Details", iconName: "pan-end-symbolic").css("flat", "details-toggle").align(h: .center)
        toggle.onClicked { [weak revealer, weak toggle] in
            guard let revealer else { return }
            revealer.isRevealed.toggle()
            toggle?.setContent(label: revealer.isRevealed ? "Hide Details" : "Details",
                               iconName: revealer.isRevealed ? "pan-down-symbolic" : "pan-end-symbolic")
        }
        return Box(.vertical, spacing: 0, [toggle, revealer])
    }
}
