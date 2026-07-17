import Foundation

public enum MTPProviderCall: String, CaseIterable, Hashable, Sendable {
    case deviceInfo
    case storages
    case walk
    case fileExists
    case deleteFiles
    case makeDirectory
    case renameFile
    case downloadFiles
    case uploadFiles
    case dispose
}

public enum MockTransferCompletion: Sendable {
    case success(Bool)
    case callFailure(MTPErrorType)
}

/// Holds a scripted transfer until the test opens it. Waiting is cancellable,
/// so a gate that is never opened models a transfer that runs until the
/// client aborts it.
public actor MockTransferGate {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    /// Returns once the gate opens, or as soon as the waiting task is
    /// cancelled (the caller checks for cancellation afterwards).
    public func wait() async {
        guard !isOpen else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.release(id) }
        }
    }

    public func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters.values
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

/// One deterministic transfer invocation used by `MockMTPProvider`.
///
/// Scripts are consumed FIFO across upload and download calls. Delays model an
/// operation that remains active after the provider has returned its streams,
/// which lets clients verify their own single-flight behavior.
public struct MockTransferScript: Sendable {
    public let events: [TransferEvent]
    public let eventInterval: Duration
    public let completionDelay: Duration
    public let completionGate: MockTransferGate?
    public let completion: MockTransferCompletion

    public init(
        events: [TransferEvent] = [],
        eventInterval: Duration = .zero,
        completionDelay: Duration = .zero,
        completionGate: MockTransferGate? = nil,
        completion: MockTransferCompletion = .success(true)
    ) {
        self.events = events
        self.eventInterval = eventInterval
        self.completionDelay = completionDelay
        self.completionGate = completionGate
        self.completion = completion
    }
}

private enum MockMTPFailure: Sendable {
    case call(MTPErrorType)
    case callError(MTPCallError)
}

/// Deterministic in-memory provider for view models and tests.
public actor MockMTPProvider: MTPDeviceProvider {
    private let mockDeviceInfo: DeviceInfo
    private let mockStorages: [StorageInfo]
    private var entriesByPath: [String: WalkEntry]
    private var scriptedFailures: [MTPProviderCall: [MockMTPFailure]]
    private var transferEvents: [TransferEvent]
    private var transferScripts: [MockTransferScript]
    private var calls: [MTPProviderCall] = []
    private let walkProgress: [WalkProgress]
    private var recordedWalkInputs: [DirectoryWalkInput] = []
    private var recordedDownloadInputs: [DownloadFilesInput] = []
    private var nextObjectID: UInt32
    private let mockDisposeResult: Bool
    private var disposed = false
    private var cancelledTransfers = 0

    public init(
        deviceInfo: DeviceInfo = DeviceInfo(),
        storages: [StorageInfo] = [],
        entries: [WalkEntry] = [],
        scriptedFailures: [MTPProviderCall: [MTPErrorType]] = [:],
        transferEvents: [TransferEvent] = [],
        transferScripts: [MockTransferScript] = [],
        disposeResult: Bool = true,
        walkProgress: [WalkProgress] = []
    ) {
        self.walkProgress = walkProgress
        mockDeviceInfo = deviceInfo
        mockStorages = storages
        entriesByPath = Dictionary(uniqueKeysWithValues: entries.map { (Self.normalize($0.path), $0) })
        self.scriptedFailures = scriptedFailures.mapValues { $0.map(MockMTPFailure.call) }
        self.transferEvents = transferEvents
        self.transferScripts = transferScripts
        mockDisposeResult = disposeResult
        nextObjectID = (entries.map(\.objectId).max() ?? 0) &+ 1
    }

    public func scriptFailure(_ type: MTPErrorType, for call: MTPProviderCall) {
        scriptedFailures[call, default: []].append(.call(type))
    }

    /// Scripts an exact error, message included, for failures whose
    /// meaning is carried by the message rather than the type.
    public func scriptFailure(_ error: MTPCallError, for call: MTPProviderCall) {
        scriptedFailures[call, default: []].append(.callError(error))
    }

    public func setTransferScripts(_ scripts: [MockTransferScript]) {
        transferScripts = scripts
    }

    public func callHistory() -> [MTPProviderCall] {
        calls
    }

    public func walkInputs() -> [DirectoryWalkInput] {
        recordedWalkInputs
    }

    public func downloadInputs() -> [DownloadFilesInput] {
        recordedDownloadInputs
    }

    public func allEntries() -> [WalkEntry] {
        entriesByPath.values.sorted { $0.path < $1.path }
    }

    /// How many transfers ended because their `result` task was cancelled.
    public func cancelledTransferCount() -> Int {
        cancelledTransfers
    }

    public func deviceInfo() async throws -> DeviceInfo {
        try check(.deviceInfo)
        return mockDeviceInfo
    }

    public func storages() async throws -> [StorageInfo] {
        try check(.storages)
        return mockStorages
    }

    public func walk(input: DirectoryWalkInput) async throws -> [WalkEntry] {
        try check(.walk)
        // The mock intentionally resolves by path, but records session-scoped
        // handle hints so higher layers can verify that they were threaded.
        recordedWalkInputs.append(input)
        let root = Self.normalize(input.fullPath)
        return entriesByPath.values
            .filter { entry in
                let path = Self.normalize(entry.path)
                guard path != root else { return false }
                guard Self.normalize(entry.parentPath) == root else { return false }
                if input.skipHiddenFiles, entry.name.hasPrefix(".") { return false }
                return true
            }
            .sorted { $0.path < $1.path }
    }

    public func walk(
        input: DirectoryWalkInput,
        onProgress: @escaping @Sendable (WalkProgress) -> Void
    ) async throws -> [WalkEntry] {
        for progress in walkProgress where progress.fullPath == input.fullPath {
            onProgress(progress)
        }
        return try await walk(input: input)
    }

    public func fileExists(input: FileExistsInput) async throws -> [FileExistsData] {
        try check(.fileExists)
        return input.files.map { path in
            FileExistsData(fullpath: path, exists: entriesByPath[Self.normalize(path)] != nil)
        }
    }

    public func deleteFiles(input: DeleteFileInput) async throws -> Bool {
        try check(.deleteFiles)
        for path in input.files.map(Self.normalize) {
            guard entriesByPath[path] != nil else {
                throw MTPCallError(message: "File not found: \(path)", type: .invalidPath)
            }
            entriesByPath = entriesByPath.filter { candidate, _ in
                candidate != path && !Self.isDescendant(candidate, of: path)
            }
        }
        return true
    }

    public func makeDirectory(input: MakeDirectoryInput) async throws -> Bool {
        try check(.makeDirectory)
        let path = Self.normalize(input.fullPath)
        guard path != "/", entriesByPath[path] == nil else {
            throw MTPCallError(message: "Invalid directory path: \(path)", type: .invalidPath)
        }
        let parent = Self.parentPath(of: path)
        if parent != "/", entriesByPath[parent]?.isFolder != true {
            throw MTPCallError(message: "Parent directory not found: \(parent)", type: .invalidPath)
        }
        entriesByPath[path] = makeEntry(path: path, isFolder: true, size: 0)
        return true
    }

    public func renameFile(input: RenameFileInput) async throws -> Bool {
        try check(.renameFile)
        let oldPath = Self.normalize(input.fullPath)
        guard !input.newFileName.isEmpty,
              !input.newFileName.contains("/"),
              let existing = entriesByPath[oldPath] else {
            throw MTPCallError(message: "Invalid rename", type: .invalidPath)
        }
        let newPath = Self.join(Self.parentPath(of: oldPath), input.newFileName)
        guard entriesByPath[newPath] == nil else {
            throw MTPCallError(message: "Destination already exists: \(newPath)", type: .invalidPath)
        }

        let affected = entriesByPath.values
            .filter { $0.path == oldPath || Self.isDescendant($0.path, of: oldPath) }
            .sorted { $0.path < $1.path }
        for entry in affected {
            entriesByPath.removeValue(forKey: Self.normalize(entry.path))
        }
        for entry in affected {
            let suffix = String(Self.normalize(entry.path).dropFirst(oldPath.count))
            let replacementPath = Self.normalize(newPath + suffix)
            entriesByPath[replacementPath] = Self.replacingPath(
                of: entry,
                with: replacementPath,
                renamedRoot: entry.path == oldPath ? existing.isFolder : entry.isFolder
            )
        }
        return true
    }

    public func downloadFiles(input: DownloadFilesInput) async throws -> TransferOperation {
        try check(.downloadFiles)
        recordedDownloadInputs.append(input)
        for source in input.sources where entriesByPath[Self.normalize(source)] == nil {
            throw MTPCallError(message: "File not found: \(source)", type: .invalidPath)
        }
        try materializeStagedDownload(input)
        return makeTransferOperation(script: nextTransferScript(), removingOnCancel: [])
    }

    public func uploadFiles(input: UploadFilesInput) async throws -> TransferOperation {
        try check(.uploadFiles)
        let destination = Self.normalize(input.destination)
        if destination != "/", entriesByPath[destination]?.isFolder != true {
            throw MTPCallError(message: "Destination not found: \(destination)", type: .invalidPath)
        }
        var created: [String] = []
        for source in input.sources {
            let name = URL(fileURLWithPath: source).lastPathComponent
            let path = Self.join(destination, name)
            if entriesByPath[path] == nil {
                entriesByPath[path] = makeEntry(path: path, isFolder: false, size: 0)
                created.append(path)
            }
        }
        // Like the real provider, a cancelled upload leaves no partial object.
        return makeTransferOperation(script: nextTransferScript(), removingOnCancel: created)
    }

    public func dispose() async throws -> Bool {
        try check(.dispose, allowDisposed: true)
        disposed = true
        return mockDisposeResult
    }

    private func check(_ call: MTPProviderCall, allowDisposed: Bool = false) throws {
        calls.append(call)
        if !allowDisposed, disposed {
            throw MTPCallError(message: "Provider is disposed", type: .general)
        }
        if var failures = scriptedFailures[call], !failures.isEmpty {
            let failure = failures.removeFirst()
            scriptedFailures[call] = failures
            switch failure {
            case let .call(type):
                throw MTPCallError(message: "Scripted \(call.rawValue) failure", type: type)
            case let .callError(error):
                throw error
            }
        }
    }

    private func nextTransferScript() -> MockTransferScript {
        guard !transferScripts.isEmpty else {
            return MockTransferScript(events: transferEvents)
        }
        return transferScripts.removeFirst()
    }

    /// Cancelling the operation's `result` aborts the script at its next
    /// step (an event, a delay or the gate), finishes with a
    /// `CancellationError` as the real provider does, and removes the objects
    /// an upload created.
    private func makeTransferOperation(
        script: MockTransferScript,
        removingOnCancel created: [String]
    ) -> TransferOperation {
        let (stream, continuation) = AsyncStream<TransferEvent>.makeStream()
        let result = Task<Bool, Error> {
            defer { continuation.finish() }
            do {
                for event in script.events {
                    if script.eventInterval != .zero {
                        try await Task.sleep(for: script.eventInterval)
                    }
                    try Task.checkCancellation()
                    continuation.yield(event)
                }
                if script.completionDelay != .zero {
                    try await Task.sleep(for: script.completionDelay)
                }
                if let completionGate = script.completionGate {
                    await completionGate.wait()
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                self.transferWasCancelled(removing: created)
                throw CancellationError()
            }
            switch script.completion {
            case let .success(result):
                return result
            case let .callFailure(type):
                throw MTPCallError(message: "Scripted transfer completion failure", type: type)
            }
        }
        return TransferOperation(progress: stream, result: result)
    }

    private func transferWasCancelled(removing created: [String]) {
        cancelledTransfers += 1
        for path in created {
            entriesByPath.removeValue(forKey: path)
        }
    }

    /// Staged conflict downloads need a real local item so the Swift completion
    /// action is exercised in mock mode. Direct mock downloads remain virtual to
    /// avoid writing to arbitrary fixture paths such as `/tmp`.
    private func materializeStagedDownload(_ input: DownloadFilesInput) throws {
        let destination = URL(fileURLWithPath: input.destination)
        guard destination.lastPathComponent.hasPrefix("AndroidRapidTransfer-Staging-") else { return }

        for source in input.sources {
            guard let entry = entriesByPath[Self.normalize(source)] else { continue }
            let item = destination.appending(path: entry.name)
            if entry.isFolder {
                try FileManager.default.createDirectory(
                    at: item,
                    withIntermediateDirectories: true
                )
            } else {
                try Data("Mock download".utf8).write(to: item)
            }
        }
    }

    private func makeEntry(path: String, isFolder: Bool, size: Int64) -> WalkEntry {
        defer { nextObjectID &+= 1 }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return WalkEntry(
            size: size,
            isFolder: isFolder,
            modified: Date(timeIntervalSince1970: 0),
            name: name,
            path: path,
            parentPath: Self.parentPath(of: path),
            extension: isFolder ? "" : URL(fileURLWithPath: path).pathExtension,
            parentId: 0,
            objectId: nextObjectID
        )
    }

    private static func replacingPath(
        of entry: WalkEntry,
        with path: String,
        renamedRoot: Bool
    ) -> WalkEntry {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return WalkEntry(
            size: entry.size,
            isFolder: renamedRoot,
            modified: entry.modified,
            name: name,
            path: path,
            parentPath: parentPath(of: path),
            extension: renamedRoot ? "" : URL(fileURLWithPath: path).pathExtension,
            parentId: entry.parentId,
            objectId: entry.objectId
        )
    }

    private static func normalize(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func parentPath(of path: String) -> String {
        let parent = URL(fileURLWithPath: normalize(path)).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private static func join(_ parent: String, _ name: String) -> String {
        normalize(URL(fileURLWithPath: normalize(parent)).appendingPathComponent(name).path)
    }

    private static func isDescendant(_ path: String, of parent: String) -> Bool {
        let parent = normalize(parent)
        let prefix = parent == "/" ? "/" : parent + "/"
        return normalize(path).hasPrefix(prefix)
    }
}
