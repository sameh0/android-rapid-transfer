import Foundation

/// A fixture date written as device wall-clock time ("2026-01-01T00:00:00Z";
/// the Z and any fraction are ignored), read in the Mac's time zone the way the
/// MTP engine reads a phone's dates.
func wallClockDate(_ string: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.date(from: String(string.prefix(19)))
}
