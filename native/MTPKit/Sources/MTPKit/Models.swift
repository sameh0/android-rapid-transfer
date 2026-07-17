import Foundation

// MARK: - Device and storage

/// What the device reports about itself (MTP GetDeviceInfo) plus the USB
/// identity of the interface it was opened through.
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var manufacturer: String
    public var model: String
    public var deviceVersion: String
    public var serialNumber: String
    public var standardVersion: Int
    public var vendorExtensionID: Int
    public var vendorExtensionVersion: Int
    public var vendorExtensionDescription: String
    public var functionalMode: Int
    public var operationsSupported: [UInt16]
    public var eventsSupported: [UInt16]
    public var devicePropertiesSupported: [UInt16]
    public var captureFormats: [UInt16]
    public var playbackFormats: [UInt16]
    public var usb: USBDeviceInfo

    public init(
        manufacturer: String = "",
        model: String = "",
        deviceVersion: String = "",
        serialNumber: String = "",
        standardVersion: Int = 0,
        vendorExtensionID: Int = 0,
        vendorExtensionVersion: Int = 0,
        vendorExtensionDescription: String = "",
        functionalMode: Int = 0,
        operationsSupported: [UInt16] = [],
        eventsSupported: [UInt16] = [],
        devicePropertiesSupported: [UInt16] = [],
        captureFormats: [UInt16] = [],
        playbackFormats: [UInt16] = [],
        usb: USBDeviceInfo = USBDeviceInfo()
    ) {
        self.manufacturer = manufacturer
        self.model = model
        self.deviceVersion = deviceVersion
        self.serialNumber = serialNumber
        self.standardVersion = standardVersion
        self.vendorExtensionID = vendorExtensionID
        self.vendorExtensionVersion = vendorExtensionVersion
        self.vendorExtensionDescription = vendorExtensionDescription
        self.functionalMode = functionalMode
        self.operationsSupported = operationsSupported
        self.eventsSupported = eventsSupported
        self.devicePropertiesSupported = devicePropertiesSupported
        self.captureFormats = captureFormats
        self.playbackFormats = playbackFormats
        self.usb = usb
    }
}

/// The USB identity of an opened device. 0 and "" mean "not reported".
public struct USBDeviceInfo: Codable, Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    /// bcdDevice.
    public var deviceRelease: Int
    public var manufacturer: String
    public var product: String
    public var serialNumber: String

    public init(vendorID: Int = 0, productID: Int = 0, deviceRelease: Int = 0, manufacturer: String = "",
                product: String = "", serialNumber: String = "") {
        self.vendorID = vendorID
        self.productID = productID
        self.deviceRelease = deviceRelease
        self.manufacturer = manufacturer
        self.product = product
        self.serialNumber = serialNumber
    }
}

/// One storage (MTP GetStorageInfo). Capacities are in bytes.
public struct StorageInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    /// The name the device gives the storage ("Internal shared storage");
    /// may be empty.
    public var storageDescription: String
    public var volumeLabel: String
    public var maxCapacity: UInt64
    public var freeSpaceInBytes: UInt64
    public var freeSpaceInObjects: UInt32
    public var storageType: UInt16
    public var filesystemType: UInt16
    public var accessCapability: UInt16

    public init(
        id: UInt32,
        storageDescription: String = "",
        volumeLabel: String = "",
        maxCapacity: UInt64 = 0,
        freeSpaceInBytes: UInt64 = 0,
        freeSpaceInObjects: UInt32 = 0,
        storageType: UInt16 = 0,
        filesystemType: UInt16 = 0,
        accessCapability: UInt16 = 0
    ) {
        self.id = id
        self.storageDescription = storageDescription
        self.volumeLabel = volumeLabel
        self.maxCapacity = maxCapacity
        self.freeSpaceInBytes = freeSpaceInBytes
        self.freeSpaceInObjects = freeSpaceInObjects
        self.storageType = storageType
        self.filesystemType = filesystemType
        self.accessCapability = accessCapability
    }
}

// MARK: - File payloads

public struct FileExistsData: Equatable, Sendable {
    public let fullpath: String
    public let exists: Bool

    public init(fullpath: String, exists: Bool) {
        self.fullpath = fullpath
        self.exists = exists
    }
}

public struct WalkEntry: Equatable, Sendable {
    public let size: Int64
    public let isFolder: Bool
    /// When the object was last modified, or nil when the device reported no
    /// usable date. MTP dates are usually zone-less device wall-clock time;
    /// the provider reads them in the Mac's time zone.
    public let modified: Date?
    public let name: String
    public let path: String
    public let parentPath: String
    public let `extension`: String
    public let parentId: UInt32
    public let objectId: UInt32

    public init(
        size: Int64,
        isFolder: Bool,
        modified: Date?,
        name: String,
        path: String,
        parentPath: String,
        extension: String,
        parentId: UInt32,
        objectId: UInt32
    ) {
        self.size = size
        self.isFolder = isFolder
        self.modified = modified
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.extension = `extension`
        self.parentId = parentId
        self.objectId = objectId
    }
}

// MARK: - Inputs

public struct FileExistsInput: Equatable, Sendable {
    public let storageId: UInt32
    public let files: [String]

    public init(storageId: UInt32, files: [String]) {
        self.storageId = storageId
        self.files = files
    }
}

public struct DeleteFileInput: Equatable, Sendable {
    public let storageId: UInt32
    public let files: [String]

    public init(storageId: UInt32, files: [String]) {
        self.storageId = storageId
        self.files = files
    }
}

public struct MakeDirectoryInput: Equatable, Sendable {
    public let storageId: UInt32
    public let fullPath: String

    public init(storageId: UInt32, fullPath: String) {
        self.storageId = storageId
        self.fullPath = fullPath
    }
}

public struct RenameFileInput: Equatable, Sendable {
    public let storageId: UInt32
    public let fullPath: String
    public let newFileName: String

    public init(storageId: UInt32, fullPath: String, newFileName: String) {
        self.storageId = storageId
        self.fullPath = fullPath
        self.newFileName = newFileName
    }
}

/// A single-directory listing request exposed by ``MTPDeviceProvider``.
///
/// Recursive walking is intentionally absent from the provider surface: callers
/// walk one directory at a time so they can stream results and stop early.
public struct DirectoryWalkInput: Equatable, Sendable {
    public let storageId: UInt32
    public let fullPath: String
    /// A per-session MTP handle hint. `nil` uses the always-correct path
    /// resolution instead.
    public let objectId: UInt32?
    public let skipDisallowedFiles: Bool
    public let skipHiddenFiles: Bool

    public init(
        storageId: UInt32,
        fullPath: String,
        objectId: UInt32? = nil,
        skipDisallowedFiles: Bool,
        skipHiddenFiles: Bool
    ) {
        self.storageId = storageId
        self.fullPath = fullPath
        self.objectId = objectId
        self.skipDisallowedFiles = skipDisallowedFiles
        self.skipHiddenFiles = skipHiddenFiles
    }
}

/// One device source paired with its per-session MTP handle hint.
public struct SourceProp: Equatable, Sendable {
    public let fullPath: String
    public let objectId: UInt32

    public init(fullPath: String, objectId: UInt32) {
        self.fullPath = fullPath
        self.objectId = objectId
    }
}

public struct DownloadFilesInput: Equatable, Sendable {
    public let storageId: UInt32
    public let sources: [String]
    /// Handle-aware sources, `nil` when none were given (the provider then
    /// resolves `sources` by path). Object IDs are never persisted across sessions.
    public let sourceProps: [SourceProp]?
    public let destination: String
    public let preprocessFiles: Bool

    public init(
        storageId: UInt32,
        sources: [String],
        sourceProps: [SourceProp] = [],
        destination: String,
        preprocessFiles: Bool
    ) {
        self.storageId = storageId
        self.sources = sources
        self.sourceProps = sourceProps.isEmpty ? nil : sourceProps
        self.destination = destination
        self.preprocessFiles = preprocessFiles
    }
}

public struct UploadFilesInput: Equatable, Sendable {
    public let storageId: UInt32
    public let sources: [String]
    public let destination: String
    public let preprocessFiles: Bool

    public init(
        storageId: UInt32,
        sources: [String],
        destination: String,
        preprocessFiles: Bool
    ) {
        self.storageId = storageId
        self.sources = sources
        self.destination = destination
        self.preprocessFiles = preprocessFiles
    }
}

// MARK: - Transfer payloads

public struct TransferPreprocessData: Equatable, Sendable {
    public let fullPath: String
    public let name: String
    public let size: Int64

    public init(fullPath: String, name: String, size: Int64) {
        self.fullPath = fullPath
        self.name = name
        self.size = size
    }
}

public struct TransferSizeInfo: Equatable, Sendable {
    public let total: Int64
    public let sent: Int64
    public let progress: Float

    public init(total: Int64, sent: Int64, progress: Float) {
        self.total = total
        self.sent = sent
        self.progress = progress
    }
}

public struct TransferProgressInfo: Equatable, Sendable {
    public let fullPath: String
    public let name: String
    public let elapsedTime: Int64
    public let speed: Double
    public let totalFiles: Int64
    public let totalDirectories: Int64
    public let filesSent: Int64
    public let filesSentProgress: Float
    public let activeFileSize: TransferSizeInfo
    public let bulkFileSize: TransferSizeInfo

    public init(
        fullPath: String,
        name: String,
        elapsedTime: Int64,
        speed: Double,
        totalFiles: Int64,
        totalDirectories: Int64,
        filesSent: Int64,
        filesSentProgress: Float,
        activeFileSize: TransferSizeInfo,
        bulkFileSize: TransferSizeInfo
    ) {
        self.fullPath = fullPath
        self.name = name
        self.elapsedTime = elapsedTime
        self.speed = speed
        self.totalFiles = totalFiles
        self.totalDirectories = totalDirectories
        self.filesSent = filesSent
        self.filesSentProgress = filesSentProgress
        self.activeFileSize = activeFileSize
        self.bulkFileSize = bulkFileSize
    }
}

// MARK: - Transfer operations

public enum TransferEvent: Equatable, Sendable {
    case preprocess(TransferPreprocessData)
    case progress(TransferProgressInfo)
}

/// A running transfer: its event stream, and the task that finishes with the
/// transfer's result. Cancelling `result` aborts the transfer.
public struct TransferOperation: Sendable {
    public let progress: AsyncStream<TransferEvent>
    public let result: Task<Bool, Error>

    public init(progress: AsyncStream<TransferEvent>, result: Task<Bool, Error>) {
        self.progress = progress
        self.result = result
    }
}
