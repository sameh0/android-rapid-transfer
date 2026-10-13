import Foundation
import MTPKit
#if canImport(OSLog)
import OSLog
#endif

/// Adapts the live connection to what the bug report needs from it.
@MainActor
public final class ConnectionControllerBugReportSession: BugReportDeviceSession {
    private let controller: DeviceConnectionController
    private let activeTransfers: @MainActor () -> Bool
    private let hotplugEnabled: @MainActor () -> Bool

    public init(
        controller: DeviceConnectionController,
        hasActiveTransfers: @escaping @MainActor () -> Bool,
        hotplugEnabled: @escaping @MainActor () -> Bool
    ) {
        self.controller = controller
        activeTransfers = hasActiveTransfers
        self.hotplugEnabled = hotplugEnabled
    }

    public var hasActiveTransfers: Bool {
        activeTransfers()
    }

    public func deviceSummary() -> String {
        BugReportDeviceSummary.describe(controller.state, lastConnectionError: controller.lastConnectionError)
    }

    public func release() async -> Bool {
        await controller.releaseDevice()
    }

    public func resume(wasActive: Bool) async {
        guard wasActive else { return }
        await controller.start(hotplugEnabled: hotplugEnabled())
    }
}

public enum BugReportDeviceSummary {
    /// - Parameter lastConnectionError: the controller's last connection
    ///   failure in full; the screens show a friendlier text, and the replug
    ///   screen none at all.
    public static func describe(_ state: DeviceConnectionController.State, lastConnectionError: String? = nil) -> String {
        var text = describeState(state)
        if let lastConnectionError {
            text += "Last connection error: \(lastConnectionError)\n"
        }
        return text
    }

    private static func describeState(_ state: DeviceConnectionController.State) -> String {
        switch state {
        case let .connected(deviceInfo, storages):
            var text = "State: connected\n\n===== Device =====\n"
            text += json(deviceInfo)
            text += "\n===== Storages (\(storages.count)) =====\n"
            text += json(storages)
            return text
        case .noDevice:
            return "State: no device connected when the report was created.\n"
        case .detecting:
            return "State: still detecting a device when the report was created.\n"
        case let .needsReplug(deviceName, message):
            return "State: needs replug\nDevice: \(deviceName ?? "unknown")\nMessage: \(message ?? "none")\n"
        case let .error(message, retryable):
            return "State: error (retryable: \(retryable))\nMessage: \(message)\n"
        }
    }

    private static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "(could not encode)\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

public extension BugReportDiagnostics {
    /// The sources the shipping app uses. Each reads state that already exists;
    /// none of them changes anything.
    @MainActor
    static func live(
        settings: AppSettings,
        batchStore: TransferBatchStore,
        bundleURL: URL = Bundle.main.bundleURL,
        processInfo: ProcessInfo = .processInfo
    ) -> BugReportDiagnostics {
        let snapshot = settings.snapshot
        let environmentText = BugReportEnvironment.describe(bundleURL: bundleURL, processInfo: processInfo)
        return BugReportDiagnostics(
            environment: { environmentText },
            appLog: { try BugReportAppLog.collect() },
            settings: {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return String(decoding: try encoder.encode(snapshot), as: UTF8.self) + "\n"
            },
            transferHistory: {
                BugReportTransferHistory.describe(await batchStore.loadAll())
            }
        )
    }
}

public enum BugReportEnvironment {
    public static func describe(bundleURL: URL, processInfo: ProcessInfo) -> String {
        let bundle = Bundle(url: bundleURL)
        let isBundled = bundleURL.pathExtension == "app"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        var text = "\(AppIdentity.name) version: \(AppVersion.current)\n"
        if isBundled, let bundle {
            let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            text += "Bundle: \(bundle.bundleIdentifier ?? "?") \(short) (\(build))\n"
        } else {
            text += "Bundle: development build (not running from an .app)\n"
        }
        #if os(macOS)
        text += "macOS: \(processInfo.operatingSystemVersionString)\n"
        text += "Mac model: \(hardwareModel() ?? "unknown")\n"
        #else
        text += "OS: \(processInfo.operatingSystemVersionString)\n"
        if let kernel = kernelRelease() { text += "Kernel: \(kernel)\n" }
        text += "Model: \(hardwareModel() ?? "unknown")\n"
        #endif
        text += "Architecture: \(architecture)\n"
        text += "Processor count: \(processInfo.processorCount)\n"
        text += "Physical memory: \(ByteCountFormatter.string(fromByteCount: Int64(processInfo.physicalMemory), countStyle: .memory))\n"
        return text
    }

    #if !canImport(Darwin)
    /// The machine's product name from the firmware tables, when readable.
    private static func hardwareModel() -> String? {
        let parts = ["sys_vendor", "product_name"].compactMap { name -> String? in
            guard let raw = try? String(contentsOfFile: "/sys/class/dmi/id/\(name)", encoding: .utf8) else {
                return nil
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The running kernel (`uname -r`); USB behaviour depends on it.
    private static func kernelRelease() -> String? {
        guard let raw = try? String(contentsOfFile: "/proc/sys/kernel/osrelease", encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    #else
    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
    #endif
}

public enum BugReportAppLog {
    public static let subsystem = AppIdentity.bundleIdentifier
    public static let entryLimit = 2_000

    #if !canImport(OSLog)
    /// This process's own log entries in the app's subsystem, from the
    /// in-memory buffer Core's loggers write to where there is no unified log.
    public static func collect(from buffer: CoreLogBuffer = .shared) throws -> String {
        let lines = buffer.entries()
            .filter { $0.subsystem == subsystem }
            .map { "\($0.date.formatted(.iso8601)) [\($0.level.rawValue)] \($0.category): \($0.message)" }
        guard !lines.isEmpty else {
            return "No \(AppIdentity.name) log messages were recorded in this session.\n"
        }
        let kept = lines.suffix(entryLimit)
        var text = kept.joined(separator: "\n") + "\n"
        if lines.count > kept.count {
            text = "[\(lines.count - kept.count) earlier entries omitted]\n" + text
        }
        return text
    }
    #else
    /// This process's own log entries in the app's subsystem. The store only
    /// exposes the current process, so nothing from other apps is read.
    public static func collect() throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            matching: NSPredicate(format: "subsystem == %@", subsystem)
        )
        let lines = entries.compactMap { entry -> String? in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return "\(log.date.formatted(.iso8601)) [\(label(log.level))] \(log.category): \(log.composedMessage)"
        }
        guard !lines.isEmpty else {
            return "No \(AppIdentity.name) log messages were recorded in this session.\n"
        }
        let kept = lines.suffix(entryLimit)
        var text = kept.joined(separator: "\n") + "\n"
        if lines.count > kept.count {
            text = "[\(lines.count - kept.count) earlier entries omitted]\n" + text
        }
        return text
    }

    private static func label(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }
    #endif
}

public enum BugReportTransferHistory {
    /// Counts and error messages only. Item paths are left out; error messages
    /// are kept because they are the useful part, and the sheet says they can
    /// contain file names.
    public static func describe(_ batches: [TransferBatchRecord]) -> String {
        guard !batches.isEmpty else { return "No saved batch copies.\n" }
        var text = "Saved batch copies: \(batches.count)\n\n"
        var failureCounts: [String: Int] = [:]
        for batch in batches.sorted(by: { $0.createdAt < $1.createdAt }) {
            text += "\(batch.createdAt.formatted(.iso8601)) · \(batch.origin.displayLabel)"
            text += " · device: \(batch.deviceLabel ?? "unknown")"
            text += " · \(batch.items.count) items: \(batch.completedCount) completed,"
            text += " \(batch.pendingCount) pending, \(batch.failedCount) failed\n"
            for item in batch.items {
                if case let .failed(message) = item.status {
                    failureCounts[message, default: 0] += 1
                }
            }
        }
        if !failureCounts.isEmpty {
            text += "\nError messages (count):\n"
            for (message, count) in failureCounts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
                text += "\(count)× \(message)\n"
            }
        }
        return text
    }
}
