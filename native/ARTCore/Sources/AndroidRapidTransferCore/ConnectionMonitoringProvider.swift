import MTPKit

actor ConnectionMonitoringProvider: MTPDeviceProvider {
    private let provider: any MTPDeviceProvider
    private let connectionLost: @Sendable (any Error) -> Void

    init(
        provider: any MTPDeviceProvider,
        connectionLost: @escaping @Sendable (any Error) -> Void
    ) {
        self.provider = provider
        self.connectionLost = connectionLost
    }

    func deviceInfo() async throws -> DeviceInfo {
        try await observing { [provider] in
            try await provider.deviceInfo()
        }
    }

    func storages() async throws -> [StorageInfo] {
        try await observing { [provider] in
            try await provider.storages()
        }
    }

    func walk(input: DirectoryWalkInput) async throws -> [WalkEntry] {
        try await observing { [provider] in
            try await provider.walk(input: input)
        }
    }

    func walk(
        input: DirectoryWalkInput,
        onProgress: @escaping @Sendable (WalkProgress) -> Void
    ) async throws -> [WalkEntry] {
        try await observing { [provider] in
            try await provider.walk(input: input, onProgress: onProgress)
        }
    }

    func fileExists(input: FileExistsInput) async throws -> [FileExistsData] {
        try await observing { [provider] in
            try await provider.fileExists(input: input)
        }
    }

    func deleteFiles(input: DeleteFileInput) async throws -> Bool {
        try await observing { [provider] in
            try await provider.deleteFiles(input: input)
        }
    }

    func makeDirectory(input: MakeDirectoryInput) async throws -> Bool {
        try await observing { [provider] in
            try await provider.makeDirectory(input: input)
        }
    }

    func renameFile(input: RenameFileInput) async throws -> Bool {
        try await observing { [provider] in
            try await provider.renameFile(input: input)
        }
    }

    func downloadFiles(input: DownloadFilesInput) async throws -> TransferOperation {
        let operation = try await observing { [provider] in
            try await provider.downloadFiles(input: input)
        }
        return monitor(operation)
    }

    func uploadFiles(input: UploadFilesInput) async throws -> TransferOperation {
        let operation = try await observing { [provider] in
            try await provider.uploadFiles(input: input)
        }
        return monitor(operation)
    }

    func dispose() async throws -> Bool {
        try await provider.dispose()
    }

    private func observing<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            connectionLost(error)
            throw error
        }
    }

    /// Wraps the transfer's result so a connection loss it reports reaches the
    /// controller. Cancelling the wrapper cancels the provider's own result:
    /// awaiting another task's `value` does not forward cancellation, and
    /// without it Stop and quit could not abort the file in flight.
    private func monitor(_ operation: TransferOperation) -> TransferOperation {
        let connectionLost = connectionLost
        let providerResult = operation.result
        let monitoredResult = Task<Bool, Error> {
            do {
                return try await withTaskCancellationHandler {
                    try await providerResult.value
                } onCancel: {
                    providerResult.cancel()
                }
            } catch {
                connectionLost(error)
                throw error
            }
        }
        return TransferOperation(progress: operation.progress, result: monitoredResult)
    }
}
