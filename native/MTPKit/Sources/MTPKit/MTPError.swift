/// What kind of failure a provider call reported. The app classifies errors by
/// this type (device loss, replug, storage full, ...) and shows `rawValue` as
/// the failure title in the transfer panel.
public enum MTPErrorType: String, CaseIterable, Hashable, Sendable {
    case mtpDetectFailed = "ErrorMtpDetectFailed"
    case deviceChanged = "ErrorDeviceChanged"
    case deviceSetup = "ErrorDeviceSetup"
    case multipleDevice = "ErrorMultipleDevice"
    case allowStorageAccess = "ErrorAllowStorageAccess"
    case deviceLocked = "ErrorDeviceLocked"
    case deviceInfo = "ErrorDeviceInfo"
    case storageInfo = "ErrorStorageInfo"
    case noStorage = "ErrorNoStorage"
    case storageFull = "ErrorStorageFull"
    case listDirectory = "ErrorListDirectory"
    case filePermission = "ErrorFilePermission"
    case localFileRead = "ErrorLocalFileRead"
    case invalidPath = "ErrorInvalidPath"
    case fileTransfer = "ErrorFileTransfer"
    case fileObjectRead = "ErrorFileObjectRead"
    case sendObject = "ErrorSendObject"
    case general = "ErrorGeneral"
}

/// The error every provider call throws for a device or file failure.
public struct MTPCallError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let type: MTPErrorType

    public init(message: String, type: MTPErrorType) {
        self.message = message
        self.type = type
    }

    public var description: String {
        message.isEmpty ? type.rawValue : "\(type.rawValue): \(message)"
    }
}
