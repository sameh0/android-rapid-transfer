import Foundation

enum DeviceBrowserError: LocalizedError {
    case noUsableStorage
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noUsableStorage:
            "The phone didn’t report any storage to open. Unlock it and try again."
        case let .operationFailed(message):
            message
        }
    }
}
