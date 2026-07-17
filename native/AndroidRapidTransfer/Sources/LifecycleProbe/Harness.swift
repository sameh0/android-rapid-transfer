import AndroidRapidTransferCore
import Foundation
import MTPKit
import SwiftMTP
import USBWatcher

func makeProvider(log: (@Sendable (String) -> Void)? = nil) -> any MTPDeviceProvider {
    SwiftMTPProvider(configuration: SwiftMTPProviderConfiguration(log: log))
}

/// The device side of the sandbox the probe may write to.
let sandboxDevicePath = "/Download/ART-Lifecycle-Probe"

/// Wires the Core objects the way `AndroidRapidTransferApp` and `ContentView`
/// do — a real `USBWatcher` feeding the controller, the transfer view model
/// following the controller's session — minus SwiftUI.
@MainActor
final class Harness {
    let watcher = USBWatcher()
    let controller: DeviceConnectionController
    let localModel: LocalBrowserViewModel
    let transferModel: TransferViewModel
    /// Every observed change of the controller's visible state.
    private(set) var timeline: [(time: Double, text: String)] = []

    private var pollTask: Task<Void, Never>?
    private var lastDescription = ""
    private var lastSessionID: UUID?
    private var loadedModel: ObjectIdentifier?
    private var lastNavigationDisabled = false
    private let factoryLog: FactoryLog

    init(localDirectory: URL) {
        let factoryLog = FactoryLog()
        self.factoryLog = factoryLog
        let providerFactory: DeviceConnectionController.ProviderFactory = {
            factoryLog.record()
            return makeProvider()
        }
        controller = DeviceConnectionController(
            providerFactory: providerFactory,
            events: watcher.events,
            startWatching: watcher.start,
            stopWatching: watcher.stop
        )
        localModel = LocalBrowserViewModel(
            rootURL: URL(fileURLWithPath: "/"),
            startURL: localDirectory
        )
        transferModel = TransferViewModel(
            localModel: localModel,
            fileConflictPolicy: { .alwaysOverwrite },
            preprocessesFiles: { _ in true }
        )
    }

    /// `ContentView.task`: the first pane to appear starts the controller.
    func start(hotplugEnabled: Bool = true) async {
        startObserving()
        await controller.paneAppeared(hotplugEnabled: hotplugEnabled)
    }

    func startObserving() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.observe()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func stopObserving() {
        pollTask?.cancel()
        pollTask = nil
    }

    var factoryCallTimes: [Double] { factoryLog.times }

    /// Mirrors `ContentView.task(id: transferSessionID)`, `BrowserPaneView`'s
    /// initial load and `DevicePaneView`'s busy-lock propagation, and records
    /// the controller's state transitions.
    private func observe() {
        let description = describeController()
        if description != lastDescription {
            lastDescription = description
            timeline.append((elapsed(), description))
            log("controller: \(description)")
        }
        if controller.transferSessionID != lastSessionID {
            lastSessionID = controller.transferSessionID
            if let queue = controller.transferQueue, let deviceModel = controller.deviceModel {
                transferModel.attach(queue: queue, deviceModel: deviceModel)
            } else {
                transferModel.detach()
            }
        }
        if let deviceModel = controller.deviceModel {
            let identifier = ObjectIdentifier(deviceModel)
            if loadedModel != identifier {
                loadedModel = identifier
                Task { await deviceModel.load() }
            }
            if lastNavigationDisabled != transferModel.isDeviceNavigationDisabled {
                lastNavigationDisabled = transferModel.isDeviceNavigationDisabled
                deviceModel.setFileOperationsDisabled(lastNavigationDisabled)
            }
        } else {
            loadedModel = nil
        }
    }

    func describeController() -> String {
        var text: String
        switch controller.state {
        case .noDevice:
            text = "noDevice"
        case .detecting:
            text = "detecting"
        case let .connected(info, storages):
            text = "connected(serial=\(Self.serial(info) ?? "?"), storages=\(storages.count))"
        case let .needsReplug(name, message):
            text = "needsReplug(\(name ?? "?"), \(message ?? "-"))"
        case let .error(message, retryable):
            text = "error(\(message), retryable=\(retryable))"
        }
        if controller.isReconnecting { text += " reconnecting" }
        if let notice = controller.connectionNotice { text += " notice=\"\(notice)\"" }
        return text
    }

    var isConnected: Bool {
        if case .connected = controller.state { return true }
        return false
    }

    var connectedSerial: String? {
        guard case let .connected(info, _) = controller.state else { return nil }
        return Self.serial(info)
    }

    static func serial(_ info: DeviceInfo) -> String? {
        [info.usb.serialNumber, info.serialNumber].first { !$0.isEmpty }
    }

    /// Whether the device pane finished loading its listing.
    var deviceModelReady: Bool {
        guard let model = controller.deviceModel else { return false }
        return model.hasLoaded && !model.isLoading && model.error == nil
    }

    func waitUntil(
        timeout: Double,
        pollEvery: Duration = .milliseconds(20),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = elapsed() + timeout
        while elapsed() < deadline {
            observe()
            if condition() { return true }
            try? await Task.sleep(for: pollEvery)
        }
        observe()
        return condition()
    }

    /// Waits for a connection whose listing has loaded.
    func waitConnectedAndLoaded(timeout: Double) async -> Bool {
        await waitUntil(timeout: timeout) { isConnected && deviceModelReady }
    }

    // MARK: - Device pane navigation (what the user does by clicking)

    func navigate(to path: String) async throws {
        guard let model = controller.deviceModel else { throw ProbeFailure("no device model") }
        let segment = BreadcrumbSegment(id: path, label: path, location: path)
        if model.currentLocation != path {
            await model.navigate(to: segment)
        }
        if let error = model.error { throw ProbeFailure("navigate \(path): \(error.message)") }
        try require(model.currentLocation == path, "navigate: at \(model.currentLocation), wanted \(path)")
    }

    /// Opens the sandbox folder, creating it if needed, and optionally clears it.
    func openSandbox(clearing: Bool) async throws {
        guard let model = controller.deviceModel else { throw ProbeFailure("no device model") }
        try await navigate(to: "/Download")
        if !model.entries.contains(where: { $0.name == "ART-Lifecycle-Probe" && $0.isDirectory }) {
            let created = await model.makeDirectory(named: "ART-Lifecycle-Probe")
            try require(created, "could not create the sandbox: \(model.error?.message ?? "?")")
        }
        try await navigate(to: sandboxDevicePath)
        if clearing, !model.entries.isEmpty {
            model.selectAll()
            let deleted = await model.deleteSelectedEntries()
            try require(deleted, "could not clear the sandbox: \(model.error?.message ?? "?")")
        }
    }

    func sandboxEntry(named name: String) async -> BrowserEntry? {
        guard let model = controller.deviceModel else { return nil }
        if model.currentLocation == sandboxDevicePath {
            await model.refresh()
        }
        return model.entries.first { $0.name == name }
    }
}

final class FactoryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Double] = []

    func record() {
        let time = elapsed()
        lock.withLock { calls.append(time) }
    }

    var times: [Double] { lock.withLock { calls } }
}
