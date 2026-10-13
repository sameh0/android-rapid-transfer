import Foundation
import Observation

/// An app known to take a phone's MTP connection before this app can, as
/// described in the "Apps that block the connection" help topic.
public struct ConflictingApp: Identifiable, Equatable, Sendable {
    public let id: String
    /// The name shown when the running app reports none.
    public let name: String
    /// One line on why it gets in the way.
    public let reason: String
    /// The help section (in the `interfering-apps` topic) that covers it.
    public let helpSectionID: String
    /// Bundle identifiers that identify it.
    public let bundleIdentifiers: Set<String>
    /// Names matched (ignoring case) when no bundle identifier is known for
    /// certain. Used only where ``bundleIdentifiers`` cannot be relied on.
    public let fallbackNames: Set<String>

    public init(
        id: String,
        name: String,
        reason: String,
        helpSectionID: String,
        bundleIdentifiers: Set<String>,
        fallbackNames: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.reason = reason
        self.helpSectionID = helpSectionID
        self.bundleIdentifiers = bundleIdentifiers
        self.fallbackNames = fallbackNames
    }

    /// Whether a running app with this bundle identifier and name is this app.
    public func matches(bundleIdentifier: String?, name: String?) -> Bool {
        if let bundleIdentifier, bundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        guard let name, !fallbackNames.isEmpty else { return false }
        let folded = name.trimmingCharacters(in: .whitespaces).lowercased()
        return fallbackNames.contains { $0.lowercased() == folded }
    }

    /// The macOS apps named in the "Apps that block the connection" topic, in
    /// the order the topic lists them.
    ///
    /// Bundle identifiers:
    /// - Image Capture, Preview and Photos: read from the apps in
    ///   /System/Applications (`mdls -name kMDItemCFBundleIdentifier`).
    /// - Android File Transfer (`com.google.android.mtpviewer`) and the agent
    ///   it installs to relaunch itself (`com.google.android.mtpagent`), Google
    ///   Drive for desktop (`com.google.drivefs`), Dropbox
    ///   (`com.getdropbox.dropbox`) and OneDrive (`com.microsoft.OneDrive`
    ///   from Microsoft's installer, `com.microsoft.OneDrive-mac` from the App
    ///   Store): the publishers' long-standing identifiers, not checked
    ///   against an installed copy.
    /// - Samsung Smart Switch: no identifier is known for certain, so it is
    ///   matched by name.
    public static func knownApps() -> [ConflictingApp] {
        let cameraUpload = String(localized: "Camera upload can grab the phone as soon as it connects.")
        let opensAutomatically = String(localized: "macOS can open it automatically when a phone connects.")
        return [
            ConflictingApp(
                id: "android-file-transfer",
                name: String(localized: "Android File Transfer"),
                reason: String(localized: "Opens itself whenever a phone connects and takes the connection."),
                helpSectionID: "android-file-transfer",
                bundleIdentifiers: ["com.google.android.mtpviewer", "com.google.android.mtpagent"]
            ),
            ConflictingApp(
                id: "google-drive",
                name: String(localized: "Google Drive"),
                reason: String(localized: "Its photo and device backup can claim a connected phone."),
                helpSectionID: "google-drive",
                bundleIdentifiers: ["com.google.drivefs"]
            ),
            ConflictingApp(
                id: "dropbox",
                name: String(localized: "Dropbox"),
                reason: cameraUpload,
                helpSectionID: "dropbox-onedrive",
                bundleIdentifiers: ["com.getdropbox.dropbox"]
            ),
            ConflictingApp(
                id: "onedrive",
                name: String(localized: "OneDrive"),
                reason: cameraUpload,
                helpSectionID: "dropbox-onedrive",
                bundleIdentifiers: ["com.microsoft.OneDrive", "com.microsoft.OneDrive-mac"]
            ),
            ConflictingApp(
                id: "image-capture",
                name: String(localized: "Image Capture"),
                reason: opensAutomatically,
                helpSectionID: "image-capture",
                bundleIdentifiers: ["com.apple.Image_Capture"]
            ),
            ConflictingApp(
                id: "preview",
                name: String(localized: "Preview"),
                reason: opensAutomatically,
                helpSectionID: "image-capture",
                bundleIdentifiers: ["com.apple.Preview"]
            ),
            ConflictingApp(
                id: "photos",
                name: String(localized: "Photos"),
                reason: opensAutomatically,
                helpSectionID: "image-capture",
                bundleIdentifiers: ["com.apple.Photos"]
            ),
            ConflictingApp(
                id: "smart-switch",
                name: String(localized: "Smart Switch"),
                reason: String(localized: "Installs components that take over Samsung phones."),
                helpSectionID: "smart-switch",
                bundleIdentifiers: [],
                fallbackNames: ["Smart Switch", "Samsung Smart Switch"]
            )
        ]
    }
}

/// A running app, as the system reports it.
public struct RunningAppSnapshot: Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let name: String?

    public init(processIdentifier: Int32, bundleIdentifier: String?, name: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// The system's list of running apps, and a way to ask one to quit.
@MainActor
public protocol RunningApplicationsProviding: AnyObject {
    var runningApplications: [RunningAppSnapshot] { get }
    /// Asks the app to quit, as ⌘Q would: it may ask to save first, or refuse.
    /// - Returns: `false` when the request could not be sent.
    func terminate(processIdentifier: Int32) -> Bool
    /// Calls `onChange` whenever an app launches or quits, until
    /// ``stopObserving()``.
    func startObserving(_ onChange: @escaping @MainActor @Sendable () -> Void)
    func stopObserving()
}

/// The running apps known to block the phone connection, with a graceful
/// quit for each.
///
/// Quitting asks the app to quit the way ⌘Q does; it is never forced. An app
/// that is still running after ``quitTimeout`` (it may be showing a save
/// prompt, or have refused) is marked ``QuitState/stillRunning`` so the user
/// can deal with it and try again.
@MainActor
@Observable
public final class ConflictingAppsModel {
    public enum QuitState: Equatable, Sendable {
        case running
        case quitting
        case stillRunning
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public var id: Int32 { processIdentifier }
        public let processIdentifier: Int32
        public let name: String
        public let app: ConflictingApp
        public internal(set) var quitState: QuitState
    }

    /// Running conflicting apps, in the order the help topic lists them.
    public private(set) var entries: [Entry] = []

    /// Whether "Quit All" has anything left to ask.
    public var canQuitAll: Bool {
        entries.contains { $0.quitState != .quitting }
    }

    @ObservationIgnored private let provider: any RunningApplicationsProviding
    @ObservationIgnored private let catalog: [ConflictingApp]
    @ObservationIgnored public let quitTimeout: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var quitChecks: [Int32: Task<Void, Never>] = [:]
    @ObservationIgnored private var isObserving = false

    public init(
        provider: any RunningApplicationsProviding,
        catalog: [ConflictingApp] = ConflictingApp.knownApps(),
        quitTimeout: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.provider = provider
        self.catalog = catalog
        self.quitTimeout = quitTimeout
        self.sleep = sleep
    }

    /// Lists the running apps and keeps the list current until ``stop()``.
    public func start() {
        if !isObserving {
            isObserving = true
            provider.startObserving { [weak self] in self?.refresh() }
        }
        refresh()
    }

    public func stop() {
        guard isObserving else { return }
        isObserving = false
        provider.stopObserving()
    }

    /// Re-reads the running apps. Apps that are no longer running drop out;
    /// the rest keep their quit state.
    public func refresh() {
        let previous = Dictionary(entries.map { ($0.processIdentifier, $0.quitState) }, uniquingKeysWith: { first, _ in first })
        var matched: [(rank: Int, entry: Entry)] = []
        var seen = Set<Int32>()
        for snapshot in provider.runningApplications {
            guard seen.insert(snapshot.processIdentifier).inserted,
                  let rank = catalog.firstIndex(where: {
                      $0.matches(bundleIdentifier: snapshot.bundleIdentifier, name: snapshot.name)
                  }) else { continue }
            let name = snapshot.name.flatMap { $0.isEmpty ? nil : $0 } ?? catalog[rank].name
            let entry = Entry(
                processIdentifier: snapshot.processIdentifier,
                name: name,
                app: catalog[rank],
                quitState: previous[snapshot.processIdentifier] ?? .running
            )
            matched.append((rank, entry))
        }
        let next = matched.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.entry.name != rhs.entry.name { return lhs.entry.name < rhs.entry.name }
            return lhs.entry.processIdentifier < rhs.entry.processIdentifier
        }.map(\.entry)

        let listed = Set(next.map(\.processIdentifier))
        for (pid, task) in quitChecks where !listed.contains(pid) {
            task.cancel()
            quitChecks[pid] = nil
        }
        if next != entries {
            entries = next
        }
    }

    /// Asks one app to quit.
    public func quit(_ entry: Entry) {
        requestQuit(processIdentifier: entry.processIdentifier)
    }

    /// Asks every listed app to quit, except those already quitting.
    public func quitAll() {
        for entry in entries where entry.quitState != .quitting {
            requestQuit(processIdentifier: entry.processIdentifier)
        }
    }

    private func requestQuit(processIdentifier pid: Int32) {
        guard let index = entries.firstIndex(where: { $0.processIdentifier == pid }),
              entries[index].quitState != .quitting else { return }
        entries[index].quitState = .quitting
        // The provider may report the app gone (and refresh the list) before
        // `terminate` returns, so look the entry up again afterwards.
        let sent = provider.terminate(processIdentifier: pid)
        guard let current = entries.firstIndex(where: { $0.processIdentifier == pid }) else { return }
        guard sent else {
            entries[current].quitState = .stillRunning
            return
        }
        quitChecks[pid]?.cancel()
        let sleep = sleep
        let timeout = quitTimeout
        quitChecks[pid] = Task { [weak self] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            self?.finishQuitCheck(processIdentifier: pid)
        }
    }

    private func finishQuitCheck(processIdentifier pid: Int32) {
        quitChecks[pid] = nil
        // Catch a quit whose notification was missed.
        refresh()
        if let index = entries.firstIndex(where: { $0.processIdentifier == pid }),
           entries[index].quitState == .quitting {
            entries[index].quitState = .stillRunning
        }
    }

    /// Waits for every pending quit check to finish. For tests.
    func waitForQuitChecks() async {
        while let task = quitChecks.values.first {
            await task.value
        }
    }
}
