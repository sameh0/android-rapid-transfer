import Foundation

public enum BrowserSortColumn: String, CaseIterable, Equatable, Sendable {
    case name
    case size
    case modified
}

public enum BrowserSortDirection: Equatable, Sendable {
    case ascending
    case descending
}

public struct BrowserSortDescriptor: Equatable, Sendable {
    public var column: BrowserSortColumn
    public var direction: BrowserSortDirection

    public init(
        column: BrowserSortColumn = .name,
        direction: BrowserSortDirection = .ascending
    ) {
        self.column = column
        self.direction = direction
    }

    public mutating func toggle(_ requestedColumn: BrowserSortColumn) {
        if column == requestedColumn {
            direction = direction == .ascending ? .descending : .ascending
        } else {
            column = requestedColumn
            direction = .ascending
        }
    }
}
