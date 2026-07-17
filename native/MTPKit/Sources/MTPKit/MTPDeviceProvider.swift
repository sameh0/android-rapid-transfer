import Foundation

public protocol MTPDeviceProvider: Sendable {
    func deviceInfo() async throws -> DeviceInfo
    func storages() async throws -> [StorageInfo]
    func walk(input: DirectoryWalkInput) async throws -> [WalkEntry]
    func walk(
        input: DirectoryWalkInput,
        onProgress: @escaping @Sendable (WalkProgress) -> Void
    ) async throws -> [WalkEntry]
    func fileExists(input: FileExistsInput) async throws -> [FileExistsData]
    func deleteFiles(input: DeleteFileInput) async throws -> Bool
    func makeDirectory(input: MakeDirectoryInput) async throws -> Bool
    func renameFile(input: RenameFileInput) async throws -> Bool
    func downloadFiles(input: DownloadFilesInput) async throws -> TransferOperation
    func uploadFiles(input: UploadFilesInput) async throws -> TransferOperation
    func dispose() async throws -> Bool
}

public extension MTPDeviceProvider {
    func walk(
        input: DirectoryWalkInput,
        onProgress: @escaping @Sendable (WalkProgress) -> Void
    ) async throws -> [WalkEntry] {
        try await walk(input: input)
    }
}
