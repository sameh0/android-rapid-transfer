public struct BrowserPaneError: Identifiable, Equatable, Sendable {
    public let id: String
    public let message: String

    public init(message: String) {
        id = message
        self.message = message
    }
}
