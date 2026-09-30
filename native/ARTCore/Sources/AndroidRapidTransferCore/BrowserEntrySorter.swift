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
                #if canImport(Darwin)
                let comparison = comparator.compare(lhs, rhs)
                #else
                let comparison = portableCompare(lhs, rhs, comparator)
                #endif
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    #if !canImport(Darwin)
    /// Apple's `KeyPathComparator(\.name)` compares strings with
    /// `localizedStandard` (Finder order: "alpha" before "Zeta", "2" before
    /// "10"); the Foundation elsewhere compares them with `<`. Names get the
    /// Finder order here too.
    private static func portableCompare(
        _ lhs: BrowserEntry,
        _ rhs: BrowserEntry,
        _ comparator: KeyPathComparator<BrowserEntry>
    ) -> ComparisonResult {
        guard comparator.keyPath == \BrowserEntry.name else {
            return comparator.compare(lhs, rhs)
        }
        let ascending = lhs.name.localizedStandardCompare(rhs.name)
        guard comparator.order == .reverse else { return ascending }
        return switch ascending {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
    #endif

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
