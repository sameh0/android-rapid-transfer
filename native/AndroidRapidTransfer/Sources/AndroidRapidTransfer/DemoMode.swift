#if DEBUG
import AndroidRapidTransferCore
import Darwin
import Foundation
import MTPKit
import USBWatcher

/// Development only: `--demo` runs the app against a scripted demo phone, for
/// recording the README's demo video and screenshots. It is compiled only
/// into debug builds, so a release can never start in it.
///
/// Unlike `--mock`, the demo phone starts unplugged. Debug › Plug In Demo
/// Phone (⌃⌥⌘P) plugs it in: the app sees a USB attach, shows its connecting
/// screen for a moment, then connects. Copies report progress at the speeds
/// measured on a real phone, uploads appear on the phone with their real
/// size and date, and downloads leave placeholder files of the right size —
/// but only inside a throwaway home (`HOME` and `CFFIXED_USER_HOME` pointing
/// somewhere other than the account's own home), so nothing is ever written
/// among the user's own files.
enum DemoMode {
    static let argument = "--demo"
    /// Where the Mac pane opens, relative to the (throwaway) home, when it exists.
    static let localStartFolder = "Pictures/Lisbon Trip"

    static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(argument)
    }

    /// The throwaway home the demo may write placeholder downloads into, or
    /// nil when `HOME` is the account's real home directory.
    static func throwawayHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        accountHome: String? = accountHomeDirectory()
    ) -> URL? {
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        let homeURL = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        if let accountHome,
           homeURL.path == URL(fileURLWithPath: accountHome).standardizedFileURL.path {
            return nil
        }
        return homeURL
    }

    static func localStartURL(home: URL? = throwawayHome()) -> URL? {
        guard let home else { return nil }
        let url = home.appending(path: localStartFolder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    private static func accountHomeDirectory() -> String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }
}

/// The demo phone's plug: the provider factory and the USB events the
/// connection controller watches.
@MainActor
final class DemoDeviceSession {
    let events: AsyncStream<USBDeviceEvent>
    private let continuation: AsyncStream<USBDeviceEvent>.Continuation
    private let plug = DemoPlug()
    private let connectDelay: Duration
    private let writableRoot: URL?

    init(connectDelay: Duration = .milliseconds(1_400), writableRoot: URL? = DemoMode.throwawayHome()) {
        (events, continuation) = AsyncStream<USBDeviceEvent>.makeStream()
        self.connectDelay = connectDelay
        self.writableRoot = writableRoot
    }

    /// Fails like the real factory while unplugged ("no device", which waits
    /// for hotplug), and connects after `connectDelay` once plugged in.
    var providerFactory: DeviceConnectionController.ProviderFactory {
        { [plug, connectDelay, writableRoot] in
            guard await plug.isPluggedIn else {
                throw MTPCallError(message: "No MTP device found.", type: .mtpDetectFailed)
            }
            try await Task.sleep(for: connectDelay)
            return DemoMTPProvider(writableRoot: writableRoot)
        }
    }

    func plugIn() {
        Task {
            await plug.set(true)
            continuation.yield(Self.event(.attached))
        }
    }

    func unplug() {
        Task {
            await plug.set(false)
            continuation.yield(Self.event(.detached))
        }
    }

    private static func event(_ kind: USBDeviceEvent.Kind) -> USBDeviceEvent {
        USBDeviceEvent(
            kind: kind,
            vendorId: 0x18D1,
            productId: 0x4EE1,
            serialNumber: DemoPhoneFixture.deviceInfo.usb.serialNumber,
            productName: DemoPhoneFixture.deviceInfo.model,
            isLikelyMTPDevice: true
        )
    }
}

private actor DemoPlug {
    private(set) var isPluggedIn = false

    func set(_ pluggedIn: Bool) {
        isPluggedIn = pluggedIn
    }
}

/// The demo phone: the mock provider's files, with copies that take as long
/// as they would over USB and leave believable results behind.
actor DemoMTPProvider: MTPDeviceProvider {
    static let uploadSpeed = 38.0
    static let downloadSpeed = 43.0

    private let mock: MockMTPProvider
    private let writableRoot: URL?
    private let tick: Duration
    /// Uploaded files' real sizes and dates; the mock records only the path.
    private var uploaded: [String: (size: Int64, date: Date)] = [:]

    init(writableRoot: URL?, tick: Duration = .milliseconds(120)) {
        mock = MockMTPProvider(
            deviceInfo: DemoPhoneFixture.deviceInfo,
            storages: DemoPhoneFixture.storages,
            entries: DemoPhoneFixture.entries
        )
        self.writableRoot = writableRoot
        self.tick = tick
    }

    func deviceInfo() async throws -> DeviceInfo { try await mock.deviceInfo() }
    func storages() async throws -> [StorageInfo] { try await mock.storages() }

    func walk(input: DirectoryWalkInput) async throws -> [WalkEntry] {
        try await mock.walk(input: input).map { entry in
            guard let upload = uploaded[entry.path] else { return entry }
            return WalkEntry(
                size: upload.size,
                isFolder: entry.isFolder,
                modified: upload.date,
                name: entry.name,
                path: entry.path,
                parentPath: entry.parentPath,
                extension: entry.extension,
                parentId: entry.parentId,
                objectId: entry.objectId
            )
        }
    }

    func fileExists(input: FileExistsInput) async throws -> [FileExistsData] {
        try await mock.fileExists(input: input)
    }

    func deleteFiles(input: DeleteFileInput) async throws -> Bool {
        try await mock.deleteFiles(input: input)
    }

    func makeDirectory(input: MakeDirectoryInput) async throws -> Bool {
        try await mock.makeDirectory(input: input)
    }

    func renameFile(input: RenameFileInput) async throws -> Bool {
        try await mock.renameFile(input: input)
    }

    func downloadFiles(input: DownloadFilesInput) async throws -> TransferOperation {
        // The mock validates the sources and fills conflict staging folders.
        _ = try await mock.downloadFiles(input: input)
        let entries = await mock.allEntries()
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let files = input.sources.compactMap { source -> DemoTransferFile? in
            guard let entry = byPath[source] else { return nil }
            let size = uploaded[entry.path]?.size ?? entry.size
            return DemoTransferFile(path: entry.path, name: entry.name, size: size, isFolder: entry.isFolder)
        }
        let placeholders = placeholderTargets(for: files, destination: input.destination)
        return run(files: files, speed: Self.downloadSpeed, preprocess: input.preprocessFiles) {
            for target in placeholders {
                Self.writePlaceholder(target)
            }
        } onCancel: {}
    }

    func uploadFiles(input: UploadFilesInput) async throws -> TransferOperation {
        let files = input.sources.map { source in
            let url = URL(fileURLWithPath: source)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            return DemoTransferFile(
                path: source,
                name: url.lastPathComponent,
                size: Int64(values?.fileSize ?? 0),
                isFolder: values?.isDirectory ?? false
            )
        }
        let existing = Set(await mock.allEntries().map(\.path))
        _ = try await mock.uploadFiles(input: input)
        let destination = input.destination == "/" ? "" : input.destination
        let created = files.map { "\(destination)/\($0.name)" }.filter { !existing.contains($0) }
        let now = Date()
        for (file, path) in zip(files, files.map { "\(destination)/\($0.name)" }) where created.contains(path) {
            uploaded[path] = (file.size, now)
        }
        return run(files: files, speed: Self.uploadSpeed, preprocess: input.preprocessFiles) {} onCancel: {
            // Like the real provider, a cancelled upload leaves nothing behind.
            await self.removeUploads(created)
        }
    }

    func dispose() async throws -> Bool {
        try await mock.dispose()
    }

    private func removeUploads(_ paths: [String]) async {
        for path in paths {
            uploaded.removeValue(forKey: path)
        }
        guard !paths.isEmpty else { return }
        _ = try? await mock.deleteFiles(input: DeleteFileInput(storageId: 0, files: paths))
    }

    private func run(
        files: [DemoTransferFile],
        speed: Double,
        preprocess: Bool,
        onSuccess: @escaping @Sendable () async -> Void,
        onCancel: @escaping @Sendable () async -> Void
    ) -> TransferOperation {
        let plan = DemoTransferPlan(files: files, speed: speed, tick: tick)
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream()
        let tick = tick
        let result = Task<Bool, Error> {
            defer { continuation.finish() }
            do {
                if preprocess {
                    for file in files {
                        continuation.yield(.preprocess(TransferPreprocessData(
                            fullPath: file.path,
                            name: file.name,
                            size: file.size
                        )))
                    }
                }
                for event in plan.events {
                    try await Task.sleep(for: tick)
                    try Task.checkCancellation()
                    continuation.yield(.progress(event))
                }
            } catch {
                await onCancel()
                throw CancellationError()
            }
            await onSuccess()
            return true
        }
        return TransferOperation(progress: stream, result: result)
    }

    private func placeholderTargets(
        for files: [DemoTransferFile],
        destination: String
    ) -> [DemoPlaceholder] {
        guard let writableRoot else { return [] }
        let folder = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL
        guard folder.path.hasPrefix(writableRoot.path + "/") || folder.path == writableRoot.path,
              !folder.lastPathComponent.hasPrefix("\(AppIdentity.fileNamePrefix)-Staging-") else {
            return []
        }
        return files.map { file in
            DemoPlaceholder(url: folder.appending(path: file.name), size: file.size, isFolder: file.isFolder)
        }
    }

    private static func writePlaceholder(_ target: DemoPlaceholder) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: target.url.path) else { return }
        if target.isFolder {
            try? manager.createDirectory(at: target.url, withIntermediateDirectories: true)
            return
        }
        // Sparse: the right size without the bytes.
        guard manager.createFile(atPath: target.url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: target.url) else { return }
        try? handle.truncate(atOffset: UInt64(max(target.size, 0)))
        try? handle.close()
    }
}

struct DemoTransferFile: Equatable, Sendable {
    let path: String
    let name: String
    let size: Int64
    let isFolder: Bool
}

private struct DemoPlaceholder: Sendable {
    let url: URL
    let size: Int64
    let isFolder: Bool
}

/// The progress events a copy of `files` produces at about `speed` MB/s,
/// one per `tick`, with the gentle wobble a real USB copy shows.
struct DemoTransferPlan {
    let events: [TransferProgressInfo]

    init(files: [DemoTransferFile], speed: Double, tick: Duration) {
        let seconds = Double(tick.components.seconds) + Double(tick.components.attoseconds) / 1e18
        let bulkTotal = files.reduce(Int64(0)) { $0 + max($1.size, 0) }
        let totalFiles = Int64(files.count)
        var events: [TransferProgressInfo] = []
        var bulkSent: Int64 = 0
        var elapsed = 0.0
        var carry = 0.0

        func percent(_ part: Int64, _ whole: Int64) -> Float {
            whole > 0 ? Float(Double(part) / Double(whole) * 100) : 100
        }

        for (index, file) in files.enumerated() {
            var activeSent: Int64 = 0
            let activeTotal = max(file.size, 0)
            repeat {
                elapsed += seconds
                let wobble = 1 + 0.035 * sin(elapsed * 2.3) + 0.015 * sin(elapsed * 7.1)
                let currentSpeed = speed * wobble
                carry += currentSpeed * 1_000_000 * seconds
                let step = min(Int64(carry), activeTotal - activeSent)
                carry -= Double(step)
                activeSent += step
                bulkSent += step
                let filesSent = Int64(index) + (activeSent >= activeTotal ? 1 : 0)
                events.append(TransferProgressInfo(
                    fullPath: file.path,
                    name: file.name,
                    elapsedTime: Int64(elapsed * 1_000),
                    speed: (currentSpeed * 100).rounded() / 100,
                    totalFiles: totalFiles,
                    totalDirectories: 0,
                    filesSent: filesSent,
                    filesSentProgress: percent(filesSent, totalFiles),
                    activeFileSize: TransferSizeInfo(
                        total: activeTotal,
                        sent: activeSent,
                        progress: percent(activeSent, activeTotal)
                    ),
                    bulkFileSize: TransferSizeInfo(
                        total: bulkTotal,
                        sent: bulkSent,
                        progress: percent(bulkSent, bulkTotal)
                    )
                ))
            } while activeSent < activeTotal
        }
        self.events = events
    }
}

/// What the demo phone holds: a lived-in phone rather than a test fixture.
enum DemoPhoneFixture {
    static let deviceInfo = DeviceInfo(
        manufacturer: "Google",
        model: "Pixel 8 Pro",
        usb: USBDeviceInfo(serialNumber: "DEMO-P8P-2026")
    )

    static let storages = [
        StorageInfo(
            id: 65537,
            storageDescription: "Internal shared storage",
            maxCapacity: 256_000_000_000,
            freeSpaceInBytes: 141_700_000_000,
            storageType: 3,
            filesystemType: 2
        ),
        StorageInfo(
            id: 131073,
            storageDescription: "SD card",
            maxCapacity: 128_000_000_000,
            freeSpaceInBytes: 96_300_000_000,
            storageType: 4,
            filesystemType: 2
        )
    ]

    static let entries: [WalkEntry] = {
        var list: [WalkEntry] = []
        var nextID: UInt32 = 1
        func add(_ path: String, folder: Bool = false, size: Int64 = 0, date: String) {
            let url = URL(fileURLWithPath: path)
            list.append(WalkEntry(
                size: size,
                isFolder: folder,
                modified: wallClock.date(from: date),
                name: url.lastPathComponent,
                path: path,
                parentPath: url.deletingLastPathComponent().path,
                extension: folder ? "" : url.pathExtension,
                parentId: 0,
                objectId: nextID
            ))
            nextID += 1
        }

        for (folder, date) in [
            ("Alarms", "2026-01-04T10:00:00"), ("Android", "2026-01-04T10:00:00"),
            ("Audiobooks", "2026-02-11T21:05:00"), ("DCIM", "2026-09-27T18:12:00"),
            ("Documents", "2026-09-21T09:40:00"), ("Download", "2026-09-26T13:10:00"),
            ("Movies", "2026-08-30T20:15:00"), ("Music", "2026-07-19T19:22:00"),
            ("Notifications", "2026-01-04T10:00:00"), ("Pictures", "2026-09-25T11:40:00"),
            ("Podcasts", "2026-06-02T07:30:00"), ("Recordings", "2026-09-03T16:02:00"),
            ("Ringtones", "2026-01-04T10:00:00")
        ] {
            add("/\(folder)", folder: true, date: date)
        }

        add("/DCIM/Camera", folder: true, date: "2026-09-27T18:12:00")
        add("/DCIM/Screenshots", folder: true, date: "2026-09-24T08:31:00")
        let camera: [(String, Int64, String)] = [
            ("PXL_20260927_181204.jpg", 4_812_331, "2026-09-27T18:12:04"),
            ("PXL_20260927_175950.jpg", 5_104_992, "2026-09-27T17:59:50"),
            ("PXL_20260927_175311.mp4", 96_418_220, "2026-09-27T17:53:11"),
            ("PXL_20260926_102233.jpg", 3_977_120, "2026-09-26T10:22:33"),
            ("PXL_20260926_101845.jpg", 4_402_761, "2026-09-26T10:18:45"),
            ("PXL_20260925_193012.jpg", 6_120_455, "2026-09-25T19:30:12"),
            ("PXL_20260925_192701.jpg", 5_733_018, "2026-09-25T19:27:01"),
            ("PXL_20260924_081455.jpg", 3_318_904, "2026-09-24T08:14:55"),
            ("PXL_20260923_172040.mp4", 58_207_331, "2026-09-23T17:20:40"),
            ("PXL_20260923_171502.jpg", 4_990_214, "2026-09-23T17:15:02"),
            ("PXL_20260922_120318.jpg", 5_211_877, "2026-09-22T12:03:18"),
            ("PXL_20260921_094011.jpg", 4_087_556, "2026-09-21T09:40:11")
        ]
        for (name, size, date) in camera {
            add("/DCIM/Camera/\(name)", size: size, date: date)
        }
        add("/DCIM/Screenshots/Screenshot_20260924-083102.png", size: 1_204_338, date: "2026-09-24T08:31:02")
        add("/DCIM/Screenshots/Screenshot_20260919-221740.png", size: 987_210, date: "2026-09-19T22:17:40")

        add("/Documents/Lease agreement.pdf", size: 2_411_093, date: "2026-09-21T09:40:00")
        add("/Documents/Notes", folder: true, date: "2026-08-14T12:00:00")
        add("/Download/boarding-pass.pdf", size: 284_119, date: "2026-09-26T13:10:12")
        add("/Download/menu.pdf", size: 1_120_554, date: "2026-09-12T19:44:03")
        add("/Download/Lisbon map.png", size: 3_402_118, date: "2026-09-20T08:02:44")
        add("/Movies/Surf lesson.mp4", size: 412_331_904, date: "2026-08-30T20:15:00")
        add("/Music/Favorites", folder: true, date: "2026-07-19T19:22:00")
        add("/Music/Favorites/Coastal Drive.mp3", size: 8_441_120, date: "2026-07-19T19:22:10")
        add("/Music/Favorites/Night Train.mp3", size: 7_902_663, date: "2026-07-19T19:23:40")
        add("/Pictures/Screenshots", folder: true, date: "2026-09-25T11:40:00")
        add("/Pictures/Edited", folder: true, date: "2026-09-18T15:10:00")
        add("/Recordings/Voice memo 12.m4a", size: 2_204_118, date: "2026-09-03T16:02:00")
        return list
    }()

    /// Fixture dates are device wall-clock times, read in the Mac's zone the
    /// way the MTP engine reads a phone's dates.
    private static let wallClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}
#endif
