#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func systemRename(_ from: String, _ to: String) -> Int32 {
    #if canImport(Darwin)
    Darwin.rename(from, to)
    #else
    Glibc.rename(from, to)
    #endif
}
import Foundation
import MTPKit

/// Builds `TransferProgressInfo` events (contract §2.4.2) and throttles them:
/// at most one every `interval` seconds while bytes move, plus one forced
/// event when each file completes.
final class TransferProgressTracker {
    private let emit: (TransferEvent) -> Void
    private let interval: TimeInterval
    private let started: TimeInterval
    let reportsTotals: Bool

    var totalFiles: Int64 = 0
    var totalDirectories: Int64 = 0
    var bulkTotal: Int64 = 0
    private(set) var filesSent: Int64 = 0
    private(set) var bulkSent: Int64 = 0
    private var activeTotal: Int64 = 0
    private var activeSent: Int64 = 0
    private var name = ""
    private var fullPath = ""
    private var lastEmit: TimeInterval = -.infinity
    private var lastPreprocess: TimeInterval = -.infinity
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private var speed: Double = 0
    private(set) var eventCount = 0

    init(emit: @escaping (TransferEvent) -> Void, reportsTotals: Bool, interval: TimeInterval) {
        self.emit = emit
        self.reportsTotals = reportsTotals
        self.interval = interval
        started = providerUptime()
        samples = [(started, 0)]
    }

    /// One preprocess event per file found, throttled like progress.
    func preprocess(fullPath: String, name: String, size: Int64) {
        let now = providerUptime()
        guard now - lastPreprocess >= interval else { return }
        lastPreprocess = now
        emit(.preprocess(TransferPreprocessData(fullPath: fullPath, name: name, size: size)))
    }

    func beginFile(name: String, fullPath: String, size: Int64) {
        self.name = name
        self.fullPath = fullPath
        activeTotal = size
        activeSent = 0
        send(force: eventCount == 0)
    }

    /// Bytes of the current file transferred so far.
    func setActiveSent(_ sent: Int64) {
        let delta = sent - activeSent
        guard delta > 0 else { return }
        activeSent = sent
        bulkSent += delta
        send(force: false)
    }

    func addActive(_ bytes: Int64) {
        setActiveSent(activeSent + bytes)
    }

    func finishFile() {
        if activeSent < activeTotal { setActiveSent(activeTotal) }
        filesSent += 1
        send(force: true)
    }

    private func percent(_ part: Int64, _ whole: Int64) -> Float {
        whole > 0 ? Float(Double(part) / Double(whole) * 100) : 0
    }

    private func send(force: Bool) {
        let now = providerUptime()
        guard force || now - lastEmit >= interval else { return }
        lastEmit = now
        // Speed over roughly the last second, in decimal MB/s.
        samples.append((now, bulkSent))
        while samples.count > 2, now - samples[1].time >= 1 { samples.removeFirst() }
        if let first = samples.first, now - first.time >= 0.05 {
            let mbps = Double(bulkSent - first.bytes) / (now - first.time) / 1_000_000
            speed = (mbps * 100).rounded() / 100
        }
        eventCount += 1
        emit(.progress(TransferProgressInfo(
            fullPath: fullPath,
            name: name,
            elapsedTime: Int64((now - started) * 1000),
            speed: speed,
            totalFiles: totalFiles,
            totalDirectories: totalDirectories,
            filesSent: filesSent,
            filesSentProgress: percent(filesSent, totalFiles),
            activeFileSize: TransferSizeInfo(total: activeTotal, sent: activeSent,
                                             progress: percent(activeSent, activeTotal)),
            bulkFileSize: TransferSizeInfo(total: bulkTotal, sent: bulkSent, progress: percent(bulkSent, bulkTotal))
        )))
    }
}

extension MTPProviderCore {
    // MARK: - Error mapping for transfers

    static func isDeviceError(_ error: Error) -> Bool {
        error is MTPResponseError || error is MTPTransportError || error is MTPProtocolError || error is PTPDecodingError
    }

    /// Maps a download or upload failure to the `MTPCallError` callers see.
    func transferFailure(_ error: Error, path: String, verb: String) -> Error {
        if error is CancellationError { return error }
        if let call = error as? MTPCallError { return ProviderError.finalize(call) }
        if let reason = session.brokenReason { return ProviderError.deviceLost(reason) }
        if let source = error as? MTPDataSourceError {
            return ProviderError.call("\(path): \(source.message)", .localFileRead)
        }
        if !Self.isDeviceError(error) {
            return ProviderError.local(error, path: path, notFoundType: .invalidPath)
        }
        return ProviderError.call("an error occured while \(verb). \(ProviderError.text(error))", .fileTransfer)
    }

    // MARK: - Download

    private struct DownloadItem {
        var devicePath: String
        var meta: ObjectMeta
        var localPath: String
    }

    /// Downloads every source (file or directory tree) into
    /// `destination`. Each file streams to a temporary name in its
    /// destination directory and is renamed into place only when complete, so
    /// a failed or cancelled download leaves no partial file behind.
    func download(_ input: DownloadFilesInput, emit: @escaping (TransferEvent) -> Void,
                  cancel: ProviderCancelFlag) throws -> Bool {
        let tracker = TransferProgressTracker(emit: emit, reportsTotals: input.preprocessFiles,
                                              interval: configuration.progressInterval)
        let destinationRoot = DevicePath.clean(input.destination.hasPrefix("/") ? input.destination
                                                                                 : "/" + input.destination)
        let sources: [(String, UInt32?)]
        if let props = input.sourceProps, !props.isEmpty {
            sources = props.map { ($0.fullPath, $0.objectId) }
        } else {
            sources = input.sources.map { ($0, nil) }
        }

        var directories: [String] = []
        var files: [DownloadItem] = []
        for (path, hint) in sources {
            try cancel.check()
            let target = try resolve(storage: input.storageId, path: path, hint: hint)
            let base = DevicePath.dir(target.fullPath)
            func localPath(for devicePath: String) -> String {
                let relative = base == "/" ? String(devicePath.dropFirst())
                                           : String(devicePath.dropFirst(base.count + 1))
                return destinationRoot == "/" ? "/" + relative : destinationRoot + "/" + relative
            }
            if !target.isFolder {
                let meta: ObjectMeta
                do { meta = try fetchMeta(target.handle) } catch { throw failure(error, .fileObjectRead) }
                if DevicePath.isDisallowed(meta.name) { continue }
                files.append(DownloadItem(devicePath: target.fullPath, meta: meta, localPath: localPath(for: target.fullPath)))
                if input.preprocessFiles {
                    tracker.preprocess(fullPath: target.fullPath, name: meta.name, size: Int64(clamping: meta.size))
                }
                continue
            }
            func collect(_ handle: UInt32, _ devicePath: String) throws {
                try cancel.check()
                let listed: [(ObjectMeta, UInt32)]
                do {
                    listed = try listDirectory(storage: input.storageId, parent: handle,
                                               progressPath: devicePath, onProgress: nil)
                } catch {
                    throw failure(error, .listDirectory)
                }
                for (meta, _) in listed where !DevicePath.isDisallowed(meta.name) {
                    let childPath = DevicePath.join(devicePath, meta.name)
                    if meta.isFolder {
                        directories.append(localPath(for: childPath))
                        try collect(meta.handle, childPath)
                    } else {
                        files.append(DownloadItem(devicePath: childPath, meta: meta, localPath: localPath(for: childPath)))
                        if input.preprocessFiles {
                            tracker.preprocess(fullPath: childPath, name: meta.name, size: Int64(clamping: meta.size))
                        }
                    }
                }
            }
            try collect(target.handle, target.fullPath)
        }
        if input.preprocessFiles {
            tracker.totalFiles = Int64(files.count)
            tracker.totalDirectories = Int64(directories.count)
            tracker.bulkTotal = files.reduce(0) { $0 + Int64(clamping: $1.meta.size) }
        }

        // Empty subdirectories are recreated; an empty top-level source
        // directory creates nothing (the walk reports only its children).
        for directory in directories {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                throw transferFailure(error, path: directory, verb: "downloading the files")
            }
        }
        for item in files {
            try cancel.check()
            try downloadFile(item, storage: input.storageId, tracker: tracker, cancel: cancel)
        }
        return true
    }

    private func downloadFile(_ item: DownloadItem, storage: UInt32, tracker: TransferProgressTracker,
                              cancel: ProviderCancelFlag) throws {
        let verb = "downloading the files"
        tracker.beginFile(name: item.meta.name, fullPath: item.devicePath, size: Int64(clamping: item.meta.size))
        let destination = URL(fileURLWithPath: item.localPath)
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw transferFailure(error, path: directory.path, verb: verb)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ProviderError.call("open \(destination.path): is a directory", .localFileRead)
        }

        let token = UUID().uuidString.prefix(8)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).artpartial-\(token)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw ProviderError.local(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO), path: temporary.path)
        }
        var completed = false
        defer {
            if !completed { unlink(temporary.path) }
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try session.getObject(item.meta.handle, sink: { chunk in
                try cancel.check()
                try handle.write(contentsOf: chunk)
                tracker.addActive(Int64(chunk.count))
            })
        } catch {
            throw transferFailure(error, path: destination.path, verb: verb)
        }
        if let date = MTPDateTime.parse(item.meta.modified)?.date(in: configuration.timeZone) {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: temporary.path)
        }
        // rename(2) replaces an existing file atomically, as os.Create would
        // have truncated and overwritten it.
        if systemRename(temporary.path, destination.path) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw ProviderError.local(POSIXError(code), path: destination.path)
        }
        completed = true
        tracker.finishFile()
    }

    // MARK: - Upload

    private struct LocalEntry {
        var url: URL
        /// Path components from the source's parent, starting with the source's own name.
        var relative: [String]
        var isDirectory: Bool
        var size: UInt64
        var modified: Date
    }

    private static func modificationDate(_ info: stat) -> Date {
        #if canImport(Darwin)
        let spec = info.st_mtimespec
        #else
        let spec = info.st_mtim
        #endif
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    /// The local tree under `root` in `filepath.Walk` order (lexical, a
    /// directory before its children), without symlinks or disallowed names.
    private func localEntries(_ root: URL) throws -> [LocalEntry] {
        var result: [LocalEntry] = []
        func visit(_ url: URL, _ relative: [String]) throws {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw ProviderError.local(POSIXError(code), path: "lstat \(url.path)", notFoundType: .localFileRead)
            }
            let kind = info.st_mode & S_IFMT
            guard !DevicePath.isDisallowed(url.lastPathComponent) else { return }
            if kind == S_IFLNK { return }
            if kind == S_IFDIR {
                result.append(LocalEntry(url: url, relative: relative, isDirectory: true, size: 0,
                                         modified: Self.modificationDate(info)))
                let children: [String]
                do {
                    children = try FileManager.default.contentsOfDirectory(atPath: url.path)
                } catch {
                    throw ProviderError.local(error, path: url.path, notFoundType: .localFileRead)
                }
                for child in children.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    try visit(url.appendingPathComponent(child), relative + [child])
                }
            } else if kind == S_IFREG {
                result.append(LocalEntry(url: url, relative: relative, isDirectory: false,
                                         size: UInt64(max(info.st_size, 0)), modified: Self.modificationDate(info)))
            }
        }
        try visit(root, [root.lastPathComponent])
        return result
    }

    func upload(_ input: UploadFilesInput, emit: @escaping (TransferEvent) -> Void,
                cancel: ProviderCancelFlag) throws -> Bool {
        let tracker = TransferProgressTracker(emit: emit, reportsTotals: input.preprocessFiles,
                                              interval: configuration.progressInterval)
        var trees: [[LocalEntry]] = []
        for source in input.sources {
            try cancel.check()
            var info = stat()
            if lstat(source, &info) != 0 {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                // A missing source: ErrorLocalFileRead with preprocessing, ErrorInvalidPath without.
                throw ProviderError.local(POSIXError(code), path: "lstat \(source)",
                                          notFoundType: input.preprocessFiles ? .localFileRead : .invalidPath)
            }
            // A symlinked source uploads nothing and succeeds.
            if info.st_mode & S_IFMT == S_IFLNK { continue }
            let entries = try localEntries(URL(fileURLWithPath: source))
            trees.append(entries)
            if input.preprocessFiles {
                for entry in entries {
                    if entry.isDirectory {
                        tracker.totalDirectories += 1
                    } else {
                        tracker.totalFiles += 1
                        tracker.bulkTotal += Int64(clamping: entry.size)
                        tracker.preprocess(fullPath: entry.url.path, name: entry.url.lastPathComponent,
                                           size: Int64(clamping: entry.size))
                    }
                }
            }
        }

        let destination = DevicePath.normalize(input.destination)
        let destinationHandle = try makeDirectory(storage: input.storageId, path: destination)
        for entries in trees {
            // Device handle and path of every uploaded directory, by relative path.
            var directories: [[String]: (UInt32, String)] = [[]: (destinationHandle, destination)]
            for entry in entries {
                try cancel.check()
                guard let (parent, parentPath) = directories[Array(entry.relative.dropLast())] else { continue }
                let name = entry.url.lastPathComponent
                if entry.isDirectory {
                    let handle = try childDirectory(storage: input.storageId, parent: parent, name: name)
                    directories[entry.relative] = (handle, DevicePath.join(parentPath, name))
                } else {
                    try uploadFile(entry, storage: input.storageId, parent: parent, parentPath: parentPath,
                                   tracker: tracker, cancel: cancel)
                }
            }
        }
        return true
    }

    private func uploadFile(_ entry: LocalEntry, storage: UInt32, parent: UInt32, parentPath: String,
                            tracker: TransferProgressTracker, cancel: ProviderCancelFlag) throws {
        let verb = "uploading files"
        let name = entry.url.lastPathComponent
        let devicePath = DevicePath.join(parentPath, name)
        tracker.beginFile(name: name, fullPath: devicePath, size: Int64(clamping: entry.size))

        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: entry.url)
        } catch {
            throw ProviderError.local(error, path: entry.url.path, notFoundType: .invalidPath)
        }
        defer { try? file.close() }

        // Replace a same-name file (case-insensitive), but
        // never delete a directory to make room for a file.
        do {
            func existing(fresh: Bool) throws -> (UInt32, Bool)? {
                let listing = try index(storage: storage, parent: parent, fresh: fresh)
                guard let handle = listing.handle(named: name) else { return nil }
                return (handle, try isFolder(handle, in: listing))
            }
            var found: (UInt32, Bool)?
            do {
                found = try existing(fresh: false)
            } catch {
                try rethrowIfFatal(error)
                guard Self.isStaleHandleError(error) else { throw error }
                invalidateCaches()
                found = try existing(fresh: true)
            }
            if let (handle, folder) = found {
                if folder {
                    throw ProviderError.call(
                        "cannot upload \(name): \(devicePath) is a directory on the device and would have to be deleted",
                        .invalidPath)
                }
                do {
                    try session.deleteObject(handle)
                } catch let error where ProviderError.responseCode(error) == PTPResponseCode.invalidObjectHandle {
                    // Already gone.
                }
                cacheDeleted(storage: storage, parent: parent, handle: handle)
            }
        } catch {
            throw transferFailure(error, path: devicePath, verb: verb)
        }

        let date = MTPDateTime.format(entry.modified, in: configuration.timeZone)
        let info = PTPObjectInfo(
            storageID: storage, objectFormat: PTPObjectFormat.undefined,
            compressedSize: entry.size >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(entry.size),
            parentObject: parent, filename: name, captureDate: date, modificationDate: date
        )
        let handle: UInt32
        do {
            handle = try session.sendObjectInfo(storageID: storage, parent: parent, info: info).handle
        } catch is PTPDecodingError {
            throw ProviderError.call("an error occured while uploading files. string too long", .fileTransfer)
        } catch {
            throw transferFailure(error, path: devicePath, verb: verb)
        }

        let source = MTPDataSource(length: entry.size) { maxLength in
            try cancel.check()
            return try file.read(upToCount: maxLength) ?? Data()
        }
        do {
            try session.sendObject(source, progress: { sent, _ in tracker.setActiveSent(Int64(clamping: sent)) })
        } catch {
            // Do not leave a partial object behind (Android usually removes a
            // cancelled one itself; a stale handle answer is harmless).
            if !session.isBroken { try? session.deleteObject(handle) }
            throw transferFailure(error, path: entry.url.path, verb: verb)
        }
        cacheCreated(storage: storage, parent: parent, meta: ObjectMeta(
            handle: handle, name: name, format: PTPObjectFormat.undefined, size: entry.size,
            modified: date, parent: parent == PTPHandle.root ? 0 : parent))
        tracker.finishFile()
    }
}
