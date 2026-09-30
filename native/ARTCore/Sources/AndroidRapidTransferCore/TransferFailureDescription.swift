import Foundation
import MTPKit

/// What the transfer panel says about a failed copy: a short human title, one
/// line of guidance on what to do next, and the untouched technical detail for
/// bug reports (shown behind a disclosure and copyable).
///
/// The provider reports failures as an ``MTPErrorType`` plus a free-form
/// message; the type alone is too coarse ("ErrorFileTransfer" covers a full
/// phone, a name the phone rejects and a dropped cable alike), so the message
/// is searched for the response names and POSIX reasons the provider embeds.
public struct TransferFailureDescription: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case deviceDisconnected
        case phoneLocked
        case allowAccess
        case phoneStorageFull
        case macStorageFull
        case phoneStorageUnavailable
        case phoneReadOnly
        case nameTooLong
        case nameNotAllowed
        case fileTooLarge
        case itemMissing
        case permissionDenied
        case localFileProblem
        case phoneBusy
        case replaceIncomplete
        case everyFileFailed
        case generic
    }

    public let kind: Kind
    public let title: String
    public let guidance: String
    /// The engine's own message, unchanged (saved with resumable batches).
    public let message: String
    /// The raw type and message, as the engine reported them.
    public let technicalDetail: String

    /// SF Symbol that illustrates the failure next to its title.
    public var symbolName: String {
        switch kind {
        case .deviceDisconnected: "cable.connector.slash"
        case .phoneLocked: "lock.iphone"
        case .allowAccess: "hand.tap"
        case .phoneStorageFull, .macStorageFull: "externaldrive.badge.exclamationmark"
        case .phoneStorageUnavailable, .phoneReadOnly: "externaldrive.badge.xmark"
        case .nameTooLong, .nameNotAllowed: "character.cursor.ibeam"
        case .fileTooLarge: "doc.badge.ellipsis"
        case .itemMissing: "questionmark.folder"
        case .permissionDenied: "lock.fill"
        case .phoneBusy: "hourglass"
        case .localFileProblem, .replaceIncomplete, .everyFileFailed, .generic:
            "exclamationmark.triangle.fill"
        }
    }

    public init(
        type: TransferQueueFailureType,
        message: String,
        direction: TransferDirection
    ) {
        let kind = Self.classify(type: type, message: message, direction: direction)
        self.kind = kind
        self.message = message
        (title, guidance) = Self.copy(for: kind, direction: direction)
        technicalDetail = Self.technicalDetail(type: type, message: message)
    }

    /// Copy for one file that failed inside a job that otherwise kept going.
    public init(fileFailureMessage message: String, direction: TransferDirection) {
        self.init(type: Self.inferredType(from: message), message: message, direction: direction)
    }

    // MARK: - Classification

    private static func classify(
        type: TransferQueueFailureType,
        message: String,
        direction: TransferDirection
    ) -> Kind {
        let text = message.lowercased()
        if type == .deviceLost || text.contains(ConnectionFatalClassifier.deviceGoneMarker.lowercased()) {
            return .deviceDisconnected
        }
        if text.hasPrefix("all "), text.contains("files failed to transfer") {
            return .everyFileFailed
        }
        if text.contains("uploaded the replacement") || text.contains("but could not rename")
            || text.contains("did not rename") {
            return .replaceIncomplete
        }
        // Message markers first: they are more specific than the type.
        if text.contains("storefull") { return .phoneStorageFull }
        if text.contains("no space left") || text.contains("out of space") {
            return direction == .download ? .macStorageFull : .phoneStorageFull
        }
        if text.contains("storereadonly") || text.contains("objectwriteprotected") { return .phoneReadOnly }
        if text.contains("storenotavailable") { return .phoneStorageUnavailable }
        if text.contains("objecttoolarge") || text.contains("file too large") { return .fileTooLarge }
        if text.contains("string too long") || text.contains("name too long") { return .nameTooLong }
        if text.contains("disallowed file") || text.contains("invalid name")
            || text.contains("not a valid name") {
            return .nameNotAllowed
        }
        if text.contains("devicebusy") { return .phoneBusy }
        if text.contains("accessdenied") { return .permissionDenied }

        guard case let .device(errorType) = type else { return .generic }
        switch errorType {
        case .deviceChanged, .mtpDetectFailed, .deviceSetup, .multipleDevice:
            return .deviceDisconnected
        case .deviceLocked:
            return .phoneLocked
        case .allowStorageAccess:
            return .allowAccess
        case .storageFull:
            return .phoneStorageFull
        case .noStorage, .storageInfo:
            return .phoneStorageUnavailable
        case .invalidPath:
            return .itemMissing
        case .filePermission:
            return .permissionDenied
        case .localFileRead:
            return .localFileProblem
        case .deviceInfo, .listDirectory, .fileTransfer, .fileObjectRead, .sendObject, .general:
            return .generic
        }
    }

    /// Per-file failures carry only the engine's message, which for provider
    /// errors starts with the type's raw value ("ErrorStorageFull: …").
    private static func inferredType(from message: String) -> TransferQueueFailureType {
        if let type = MTPErrorType.allCases.first(where: { message.hasPrefix($0.rawValue) }) {
            return .device(type)
        }
        return .unknown
    }

    // MARK: - Copy

    private static func copy(
        for kind: Kind,
        direction: TransferDirection
    ) -> (title: String, guidance: String) {
        switch kind {
        case .deviceDisconnected:
            ("Phone disconnected",
             "Reconnect the phone, unlock it and choose File transfer, then try again.")
        case .phoneLocked:
            ("Phone is locked", "Unlock the phone and keep its screen on, then try again.")
        case .allowAccess:
            ("Allow access on the phone",
             "Tap Allow on the phone’s “Allow access to phone data?” prompt, then try again.")
        case .phoneStorageFull:
            ("Not enough space on the phone", "Free up space on the phone, then try again.")
        #if os(Linux)
        case .macStorageFull:
            ("Not enough space on this computer", "Free up space on this computer or pick another folder.")
        #else
        case .macStorageFull:
            ("Not enough space on this Mac", "Free up space on this Mac or pick another folder.")
        #endif
        case .phoneStorageUnavailable:
            ("Phone storage unavailable",
             "The phone isn’t sharing this storage right now. Unlock it or reinsert the SD card.")
        case .phoneReadOnly:
            ("This storage is read-only", "Choose a different folder or storage on the phone.")
        case .nameTooLong:
            ("File name too long", "Shorten the name and try again.")
        case .nameNotAllowed:
            ("File name not allowed",
             "Android doesn’t accept this name. Rename the file and try again.")
        case .fileTooLarge:
            ("File too large for the phone",
             "This storage can’t hold files over 4 GB. Try the phone’s internal storage.")
        case .itemMissing:
            direction == .download
                ? ("File no longer on the phone", "It may have been moved or deleted. Refresh and try again.")
                : ("File or folder not found", "It may have been moved or deleted. Refresh and try again.")
        #if os(Linux)
        case .permissionDenied:
            direction == .download
                ? ("Can’t save here", "You don’t have permission to write to that folder. Pick another one.")
                : ("Access denied", "The file couldn’t be read, or the phone refused it.")
        case .localFileProblem:
            direction == .download
                ? ("Couldn’t save the file", "Something went wrong writing to this computer. Try again.")
                : ("Couldn’t read the file", "Check the file still opens on this computer, then try again.")
        #else
        case .permissionDenied:
            direction == .download
                ? ("Can’t save here", "This Mac won’t let the app write to that folder. Pick another one.")
                : ("Access denied", "The file couldn’t be read, or the phone refused it.")
        case .localFileProblem:
            direction == .download
                ? ("Couldn’t save the file", "Something went wrong writing to this Mac. Try again.")
                : ("Couldn’t read the file", "Check the file still opens on this Mac, then try again.")
        #endif
        case .phoneBusy:
            ("Phone is busy", "Wait a moment, then try again.")
        case .replaceIncomplete:
            ("Replace didn’t finish",
             "The new copy was kept on the phone. The details show its temporary name.")
        case .everyFileFailed:
            ("None of the files copied", "See the details below, then try again.")
        case .generic:
            ("Copy didn’t finish",
             "Try again. If it keeps failing, reconnect the phone.")
        }
    }

    private static func technicalDetail(type: TransferQueueFailureType, message: String) -> String {
        let prefix: String = switch type {
        case .deviceLost: "Device lost"
        case let .device(errorType): errorType.rawValue
        case .unknown: "Transfer error"
        }
        guard !message.isEmpty else { return prefix }
        // Provider messages already lead with their type's raw value.
        if message.hasPrefix(prefix) { return message }
        return "\(prefix): \(message)"
    }
}
