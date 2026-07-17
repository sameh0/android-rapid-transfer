/// Advisory progress for the directory currently being listed.
public struct WalkProgress: Equatable, Sendable {
    public let fullPath: String
    public let itemCount: Int
    public let fractionCompleted: Double

    public init(fullPath: String, itemCount: Int, fractionCompleted: Double) {
        self.fullPath = fullPath
        self.itemCount = itemCount
        self.fractionCompleted = fractionCompleted
    }
}
