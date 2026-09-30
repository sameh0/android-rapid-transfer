import Foundation

// Core logs through `os.Logger` on Apple platforms, where the unified log also
// feeds bug reports (`BugReportAppLog` reads it back through `OSLogStore`).
//
// Elsewhere there is no unified log, so this file supplies a `Logger` with the
// subset of `os.Logger`'s API that Core uses (`Logger(subsystem:category:)`,
// `info`/`notice`/`debug`/`error`/`fault`, interpolation with `privacy:`).
// Each message goes to standard error and into `CoreLogBuffer`, an in-memory
// ring buffer that bug reports read instead of `OSLogStore`. Call sites are
// the same on every platform.

/// Messages kept in memory for bug reports on platforms without a unified log.
/// Thread-safe; the oldest entries are dropped past `capacity`.
public final class CoreLogBuffer: @unchecked Sendable {
    public enum Level: String, Sendable {
        case debug, info, notice, error, fault
    }

    public struct Entry: Sendable, Equatable {
        public let date: Date
        public let level: Level
        public let subsystem: String
        public let category: String
        public let message: String
    }

    /// The process-wide buffer Core's loggers write to.
    public static let shared = CoreLogBuffer()

    public let capacity: Int
    /// Whether each message is also written to standard error.
    public var echoesToStandardError: Bool {
        get { lock.withLock { echo } }
        set { lock.withLock { echo = newValue } }
    }

    private let lock = NSLock()
    private var storage: [Entry] = []
    private var start = 0
    private var echo: Bool

    public init(capacity: Int = 4_000, echoesToStandardError: Bool = true) {
        self.capacity = max(1, capacity)
        echo = echoesToStandardError
    }

    public func append(_ entry: Entry) {
        let shouldEcho = lock.withLock { () -> Bool in
            if storage.count < capacity {
                storage.append(entry)
            } else {
                storage[start] = entry
                start = (start + 1) % capacity
            }
            return echo
        }
        guard shouldEcho else { return }
        let line = "\(entry.date.formatted(.iso8601)) [\(entry.level.rawValue)] \(entry.category): \(entry.message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// The kept entries, oldest first.
    public func entries() -> [Entry] {
        lock.withLock { Array(storage[start...] + storage[..<start]) }
    }

    public func removeAll() {
        lock.withLock {
            storage.removeAll()
            start = 0
        }
    }
}

#if !canImport(os)
/// Mirrors `OSLogPrivacy`. Core logs nothing private, so it is accepted and ignored.
struct CoreLogPrivacy: Sendable {
    static let `public` = CoreLogPrivacy()
    static let `private` = CoreLogPrivacy()
    static let auto = CoreLogPrivacy()
}

/// Mirrors `OSLogMessage`: a string built by interpolation.
struct CoreLogMessage: ExpressibleByStringInterpolation, Sendable {
    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        mutating func appendInterpolation(_ value: @autoclosure () -> some Any, privacy: CoreLogPrivacy = .auto) {
            text += String(describing: value())
        }
    }

    let text: String

    init(stringLiteral value: String) {
        text = value
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }
}

/// The subset of `os.Logger` Core uses, backed by `CoreLogBuffer.shared`.
struct Logger: Sendable {
    let subsystem: String
    let category: String

    init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }

    func debug(_ message: CoreLogMessage) { log(.debug, message) }
    func info(_ message: CoreLogMessage) { log(.info, message) }
    func notice(_ message: CoreLogMessage) { log(.notice, message) }
    func error(_ message: CoreLogMessage) { log(.error, message) }
    func fault(_ message: CoreLogMessage) { log(.fault, message) }

    private func log(_ level: CoreLogBuffer.Level, _ message: CoreLogMessage) {
        CoreLogBuffer.shared.append(
            CoreLogBuffer.Entry(
                date: Date(),
                level: level,
                subsystem: subsystem,
                category: category,
                message: message.text
            )
        )
    }
}
#endif
