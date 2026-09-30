import Foundation

public enum TransferExportError: LocalizedError, Sendable {
    case deviceUnavailable
    case transferFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            "The phone is no longer available."
        case let .transferFailed(message):
            message
        case .cancelled:
            "The transfer was cancelled."
        }
    }
}
