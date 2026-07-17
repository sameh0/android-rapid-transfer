import Foundation

/// Sorts a listing by the pane's column. With `directoriesFirst` ("Show
/// directories first", default on) folders are grouped ahead of files
/// and each group keeps the chosen order; without it, folders and files mix.
enum BrowserEntrySorter {
    static func sorted(
        _ entries: [BrowserEntry],
        by descriptor: BrowserSortDescriptor,
        directoriesFirst: Bool = true
    ) -> [BrowserEntry] {
        entries.sorted { lhs, rhs in
            if directoriesFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let comparison = compare(lhs, rhs, column: descriptor.column)
            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            return switch descriptor.direction {
            case .ascending:
                comparison == .orderedAscending
            case .descending:
                comparison == .orderedDescending
            }
        }
    }

    static func sorted(
        _ entries: [BrowserEntry],
        using comparators: [KeyPathComparator<BrowserEntry>],
        directoriesFirst: Bool = true
    ) -> [BrowserEntry] {
        entries.sorted { lhs, rhs in
            if directoriesFirst, lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            for comparator in comparators {
                let comparison = comparator.compare(lhs, rhs)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func compare(
        _ lhs: BrowserEntry,
        _ rhs: BrowserEntry,
        column: BrowserSortColumn
    ) -> ComparisonResult {
        switch column {
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            compareValues(lhs.size ?? 0, rhs.size ?? 0)
        case .modified:
            compareValues(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
        }
    }

    private static func compareValues<Value: Comparable>(
        _ lhs: Value,
        _ rhs: Value
    ) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
