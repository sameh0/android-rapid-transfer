import Foundation

/// A modification-date window used to pick files out of a device folder tree.
///
/// The upper bound is *exclusive*. Callers that think in whole calendar days —
/// which is what the picker offers — should build the filter with
/// ``calendarDays(from:through:in:)`` rather than trying to name the last
/// representable instant of the final day, which is not expressible without
/// picking an arbitrary sub-second epsilon.
public struct DateRangeFilter: Equatable, Sendable {
    /// Inclusive lower bound: a file modified at exactly this instant matches.
    public let start: Date
    /// Exclusive upper bound. `nil` means "until now" — no upper bound at all,
    /// which also keeps a range open for files whose clock runs ahead of ours.
    public let end: Date?

    public init(start: Date, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    /// Builds a filter spanning whole calendar days, treating `through` as an
    /// *inclusive* day.
    ///
    /// A user asking for "July 4 through July 10" expects a file modified at
    /// 23:59 on July 10 to be included, so the inclusive end day is converted
    /// into an exclusive bound at the start of the following day.
    public static func calendarDays(
        from start: Date,
        through end: Date? = nil,
        in calendar: Calendar = .current
    ) -> DateRangeFilter {
        let startOfRange = calendar.startOfDay(for: start)
        guard let end else {
            return DateRangeFilter(start: startOfRange)
        }
        let finalDay = calendar.startOfDay(for: end)
        // Falling back to `finalDay` would exclude the whole final day — the very
        // thing this factory exists to prevent — so degrade to a flat 24 hours
        // instead if the calendar cannot advance the date.
        let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: finalDay)
            ?? finalDay.addingTimeInterval(24 * 60 * 60)
        return DateRangeFilter(start: startOfRange, end: exclusiveEnd)
    }

    /// `true` when `date` is at or after ``start`` and strictly before ``end``.
    public func matches(_ date: Date) -> Bool {
        guard date >= start else { return false }
        guard let end else { return true }
        return date < end
    }

    /// Entries whose modification date the device never reported cannot be
    /// placed inside the window, so they are excluded rather than guessed at.
    /// `BrowserEntry.modified` is nil whenever the device reported no usable
    /// date.
    public func matches(_ entry: BrowserEntry) -> Bool {
        guard let modified = entry.modified else { return false }
        return matches(modified)
    }

    /// `false` when the bounds describe a window that can never contain a file,
    /// which the UI uses to keep the scan buttons disabled.
    public var isValid: Bool {
        guard let end else { return true }
        return start < end
    }
}
