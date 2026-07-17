public struct BreadcrumbSegment: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let location: String

    public init(id: String, label: String, location: String) {
        self.id = id
        self.label = label
        self.location = location
    }
}
