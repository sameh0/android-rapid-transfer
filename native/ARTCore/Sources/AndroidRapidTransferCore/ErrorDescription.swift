import MTPKit

enum ErrorDescription {
    static func message(for error: any Error) -> String {
        if let callError = error as? MTPCallError {
            return callError.description
        }
        return error.localizedDescription
    }
}
