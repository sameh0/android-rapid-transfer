import Foundation
import MTPKit

// MARK: - Device paths

/// Device-side path arithmetic: absolute, slash-separated, lexically cleaned.
enum DevicePath {
    /// Prefixes "/" when missing, then cleans the path.
    static func normalize(_ path: String) -> String {
        clean(path.hasPrefix("/") ? path : "/" + path)
    }

    /// Lexical cleaning: collapses slashes, resolves "." and "..".
    static func clean(_ path: String) -> String {
        if path.isEmpty { return "." }
        let rooted = path.hasPrefix("/")
        var out: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if let last = out.last, last != ".." {
                    out.removeLast()
                } else if !rooted {
                    out.append("..")
                }
                continue
            }
            out.append(component)
        }
        let joined = out.joined(separator: "/")
        if rooted { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// Components of a normalized path ("/" has none).
    static func components(_ normalized: String) -> [String] {
        normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Go `path.Dir`.
    static func dir(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "." }
        return clean(String(path[...slash]))
    }

    /// Last component of a normalized path ("" for "/").
    static func base(_ normalized: String) -> String {
        components(normalized).last ?? ""
    }

    /// `parent` and `name` joined with "/", then cleaned.
    static func join(_ parent: String, _ name: String) -> String {
        clean(parent + "/" + name)
    }

    /// Case-insensitive comparison key (Go `strings.EqualFold` semantics,
    /// plus canonical equivalence from Swift string comparison).
    static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: nil)
    }

    /// The file extension: "" for folders; "tar.<ext>" for "x.tar.<ext>";
    /// otherwise the text after the last dot ("" when there is none).
    static func fileExtension(_ name: String, isFolder: Bool) -> String {
        if isFolder { return "" }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2, parts[parts.count - 2] == "tar" {
            return "tar.\(parts[parts.count - 1])"
        }
        if parts.count > 1 { return String(parts[parts.count - 1]) }
        return ""
    }

    /// Names never listed or transferred when disallowed files are skipped.
    static let disallowedNames: Set<String> = [".DS_Store", "[-----DS_Store.mtp.test----].txt"]

    static func isDisallowed(_ name: String) -> Bool { disallowedNames.contains(name) }
    static func isHidden(_ name: String) -> Bool { name.hasPrefix(".") }
}

// MARK: - MTP dates

/// A PTP DateTime ("YYYYMMDDThhmmss[.s][Z|±hhmm]") kept as wall-clock fields.
///
/// Parsing is lenient: trailing dots (Samsung) and
/// a trailing "Z" (Jolla) are stripped, a numeric zone (Lumia) is accepted and
/// fractional seconds after the seconds field are kept.
struct MTPDateTime: Equatable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var millisecond: Int
    /// Seconds east of UTC when the device sent a numeric zone.
    var offsetSeconds: Int?

    static func parse(_ raw: String) -> MTPDateTime? {
        var s = Substring(raw)
        while s.hasSuffix(".") { s.removeLast() }
        while s.hasSuffix("Z") { s.removeLast() }
        let chars = Array(s)
        guard chars.count >= 15, chars[8] == "T" else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            let text = chars[range]
            guard text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(text))
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15)
        else { return nil }

        var rest = chars[15...]
        var millisecond = 0
        if rest.first == "." || rest.first == "," {
            rest = rest.dropFirst()
            var digits = ""
            while let c = rest.first, c.isASCII, c.isNumber {
                digits.append(c)
                rest = rest.dropFirst()
            }
            guard !digits.isEmpty else { return nil }
            let padded = (digits + "000").prefix(3)
            millisecond = Int(padded) ?? 0
        }
        var offset: Int?
        if let sign = rest.first, sign == "+" || sign == "-" {
            let zone = Array(rest.dropFirst())
            guard zone.count == 4, zone.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let hh = Int(String(zone[0..<2])), let mm = Int(String(zone[2..<4])) else { return nil }
            offset = (hh * 3600 + mm * 60) * (sign == "-" ? -1 : 1)
        } else if !rest.isEmpty {
            return nil
        }

        guard (1...12).contains(month), hour < 24, minute < 60, second < 60, day >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: firstOfMonth), days.contains(day)
        else { return nil }
        return MTPDateTime(year: year, month: month, day: day, hour: hour, minute: minute,
                           second: second, millisecond: millisecond, offsetSeconds: offset)
    }

    /// The instant this date names: the device's numeric zone when it sent
    /// one, otherwise `zone` (the Mac's local time zone). Reading the
    /// wall clock as UTC instead would shift every mtime by the zone offset.
    func date(in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = offsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? zone
        var components = DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second)
        components.nanosecond = millisecond * 1_000_000
        return calendar.date(from: components)
    }

    /// "YYYYMMDDThhmmss" wall-clock time of `date` in `zone`, without a zone suffix.
    static func format(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

// MARK: - Errors

/// Builds the `MTPCallError`s the app inspects (contract §0.1).
enum ProviderError {
    /// Every existing classifier treats a message containing this as device loss.
    static let noDeviceMarker = "LIBUSB_ERROR_NO_DEVICE"

    /// A `MTPCallError`, its type overridden when the message names a known failure.
    static func call(_ message: String, _ type: MTPErrorType) -> MTPCallError {
        finalize(MTPCallError(message: message, type: type))
    }

    static func finalize(_ error: MTPCallError) -> MTPCallError {
        let message = error.message
        var type = error.type
        guard type != .deviceChanged else { return error }
        if message.contains("allow storage access") { type = .allowStorageAccess }
        if message.contains("device is not open") { type = .deviceLocked }
        if type == .deviceInfo, message.contains(noDeviceMarker) { type = .deviceChanged }
        if message.contains("more than 1 device") { type = .multipleDevice }
        if message.contains("StoreFull") { type = .storageFull }
        if message.contains("StoreNotAvailable") { type = .noStorage }
        return MTPCallError(message: message, type: type)
    }

    /// The session is gone (USB error, lost sync, vanished phone). Reported as
    /// `.deviceChanged` with the libusb marker so the app reconnects.
    static func deviceLost(_ detail: String) -> MTPCallError {
        MTPCallError(message: "\(noDeviceMarker): the MTP session ended (\(detail))", type: .deviceChanged)
    }

    /// Go renders a failing response as its RC name.
    static func text(_ error: Error) -> String {
        switch error {
        case let response as MTPResponseError:
            return PTPResponseCode.name(response.code)
        case let transport as MTPTransportError:
            return transport.description
        case let call as MTPCallError:
            return call.message
        default:
            return "\(error)"
        }
    }

    static func isNotFound(_ error: Error) -> Bool {
        (error as? MTPCallError)?.type == .invalidPath
    }

    static func responseCode(_ error: Error) -> UInt16? {
        (error as? MTPResponseError)?.code
    }

    /// A local file-system failure, mapped to an `MTPCallError` by its POSIX code.
    static func local(_ error: Error, path: String, notFoundType: MTPErrorType = .invalidPath) -> MTPCallError {
        let ns = error as NSError
        var posix: Int32?
        if ns.domain == NSPOSIXErrorDomain {
            posix = Int32(ns.code)
        } else if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying.domain == NSPOSIXErrorDomain {
            posix = Int32(underlying.code)
        } else if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: posix = EACCES
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: posix = ENOENT
            case NSFileWriteOutOfSpaceError: posix = ENOSPC
            default: break
            }
        }
        // Go's syscall messages are lower-case ("no such file or directory").
        let reason = posix.map { code -> String in
            let text = String(cString: strerror(code))
            return text.prefix(1).lowercased() + text.dropFirst()
        } ?? ns.localizedDescription
        let message = "\(path): \(reason)"
        switch posix {
        case EACCES, EPERM: return MTPCallError(message: message, type: .filePermission)
        case ENOENT: return MTPCallError(message: message, type: notFoundType)
        default: return MTPCallError(message: message, type: .localFileRead)
        }
    }
}

// MARK: - Small concurrency helpers

/// A one-shot result that async callers can await from any thread.
final class ProviderPromise<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    func fulfill(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume(with: result) }
    }

    var value: Value {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }
}

/// Set from any thread, polled by the I/O thread between bulk chunks.
final class ProviderCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Monotonic seconds, for throttling and speed.
@inline(__always)
func providerUptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
