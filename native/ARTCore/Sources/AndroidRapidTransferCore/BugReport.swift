import Foundation

public enum BugReportError: Error, Equatable, LocalizedError {
    /// Running the diagnostic releases the device, which would abort copies.
    case transfersInProgress
    case couldNotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .transfersInProgress:
            "Finish or stop the copies in progress first. Creating a report briefly disconnects the phone."
        case let .couldNotWrite(message):
            "The report could not be saved: \(message)"
        }
    }
}

/// The device connection as the report needs it. The app adapts
/// ``DeviceConnectionController``; tests record the calls.
@MainActor
public protocol BugReportDeviceSession: AnyObject {
    var hasActiveTransfers: Bool { get }
    /// What the app knows about the phone, captured before it is released.
    func deviceSummary() -> String
    /// Frees the USB interface for the diagnostic tool. Must not return until
    /// the device session is actually closed. Returns whether a session was
    /// running and should be resumed.
    func release() async -> Bool
    func resume(wasActive: Bool) async
}

/// Each source may fail independently; a failure becomes a note in the bundle
/// instead of losing the rest of the report.
public struct BugReportDiagnostics: Sendable {
    public var environment: @Sendable () async throws -> String
    public var appLog: @Sendable () async throws -> String
    public var settings: @Sendable () async throws -> String
    public var transferHistory: @Sendable () async throws -> String

    public init(
        environment: @escaping @Sendable () async throws -> String,
        appLog: @escaping @Sendable () async throws -> String,
        settings: @escaping @Sendable () async throws -> String,
        transferHistory: @escaping @Sendable () async throws -> String
    ) {
        self.environment = environment
        self.appLog = appLog
        self.settings = settings
        self.transferHistory = transferHistory
    }
}

public protocol BugReportArchiving: Sendable {
    /// Writes a zip of `directory` (including the directory itself) to `destination`.
    func archive(directory: URL, to destination: URL) throws
}

#if canImport(Darwin)
/// Zips with the system's own archiver via file coordination: no bundled zip
/// code and no child process.
public struct FileCoordinatorArchiver: BugReportArchiving {
    public init() {}

    public func archive(directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: .forUploading,
            error: &coordinationError
        ) { zipURL in
            // The coordinator deletes its temporary zip when this block returns.
            do {
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            throw error
        }
    }
}
#endif

/// One file in the report, described in words the user sees before creating it.
public struct BugReportItem: Equatable, Sendable {
    public let fileName: String
    public let description: String

    public init(fileName: String, description: String) {
        self.fileName = fileName
        self.description = description
    }
}

@MainActor
public final class BugReportGenerator {
    nonisolated public static let folderName = "Android-Rapid-Transfer-Bug-Report"
    nonisolated public static let defaultFileName = "Android-Rapid-Transfer-Bug-Report.zip"

    #if os(macOS)
    nonisolated static let environmentDescription = "\(AppIdentity.name) version, macOS version and Mac model"
    #else
    nonisolated static let environmentDescription = "\(AppIdentity.name) version, operating system, kernel and computer model"
    #endif

    /// The single source of truth for what the bundle contains; the sheet shows
    /// this list before anything is collected. `diagnostic` is the device
    /// diagnostic's file.
    nonisolated public static func contents(diagnostic: BugReportItem = .deviceDiagnostic) -> [BugReportItem] {
        [
            BugReportItem(
                fileName: "environment.txt",
                description: environmentDescription
            ),
            BugReportItem(
                fileName: "device.txt",
                description: "The connected phone's model, manufacturer, serial number and storage names"
            ),
            diagnostic,
            BugReportItem(
                fileName: "app-log.txt",
                description: "\(AppIdentity.name)'s own log messages from this session"
            ),
            BugReportItem(
                fileName: "settings.json",
                description: "Your \(AppIdentity.name) settings (view options, theme, conflict policy)"
            ),
            BugReportItem(
                fileName: "transfer-history.txt",
                description: "A summary of saved batch copies and their error messages, which can include file names"
            )
        ]
    }

    /// What this generator's bundle contains.
    public var contents: [BugReportItem] {
        Self.contents(diagnostic: debugTool.reportItem)
    }

    private let session: any BugReportDeviceSession
    private let debugTool: any DebugToolRunning
    private let diagnostics: BugReportDiagnostics
    private let archiver: any BugReportArchiving
    private let outputDirectory: URL
    private let fileName: String
    private let now: @Sendable () -> Date

    public init(
        session: any BugReportDeviceSession,
        debugTool: any DebugToolRunning,
        diagnostics: BugReportDiagnostics,
        archiver: any BugReportArchiving = BugReportArchivers.platformDefault,
        outputDirectory: URL,
        fileName: String = defaultFileName,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.debugTool = debugTool
        self.diagnostics = diagnostics
        self.archiver = archiver
        self.outputDirectory = outputDirectory
        self.fileName = fileName
        self.now = now
    }

    /// Builds the report and returns the zip's location. The device is released
    /// only for the diagnostic tool and is always resumed afterwards, whatever
    /// the tool did, before anything else is collected. `onStage` hears each
    /// stage as it starts.
    public func generate(onStage: (BugReportStage) -> Void = { _ in }) async throws -> URL {
        guard !session.hasActiveTransfers else {
            throw BugReportError.transfersInProgress
        }

        let generatedAt = now()
        let device = session.deviceSummary()
        onStage(.release)
        let wasActive = await session.release()
        onStage(.diagnose)
        let tool = await debugTool.run()
        await session.resume(wasActive: wasActive)
        onStage(.collect)

        let diagnosticItem = debugTool.reportItem
        var files: [String: String] = [
            "README.txt": Self.readme(generatedAt: generatedAt, diagnostic: diagnosticItem, toolSucceeded: tool.succeeded),
            "device.txt": device,
            diagnosticItem.fileName: tool.reportText
        ]
        files["environment.txt"] = await Self.collect(diagnostics.environment)
        files["app-log.txt"] = await Self.collect(diagnostics.appLog)
        files["settings.json"] = await Self.collect(diagnostics.settings)
        files["transfer-history.txt"] = await Self.collect(diagnostics.transferHistory)

        let archiver = archiver
        let destination = outputDirectory.appending(path: fileName)
        let snapshot = files
        onStage(.archive)
        do {
            try await Task.detached {
                try Self.writeArchive(files: snapshot, archiver: archiver, destination: destination)
            }.value
        } catch let error as BugReportError {
            throw error
        } catch {
            throw BugReportError.couldNotWrite(ErrorDescription.message(for: error))
        }
        return destination
    }

    private static func collect(_ source: @Sendable () async throws -> String) async -> String {
        do {
            return try await source()
        } catch {
            return "Could not collect this section: \(ErrorDescription.message(for: error))\n"
        }
    }

    /// Stages the files, zips them next to nothing the user owns, and only then
    /// replaces any previous report — a failed run never deletes the old zip.
    nonisolated private static func writeArchive(
        files: [String: String],
        archiver: any BugReportArchiving,
        destination: URL
    ) throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appending(path: "\(AppIdentity.fileNamePrefix)-bug-report-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: workspace) }

        let staging = workspace.appending(path: folderName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: staging.appending(path: name), options: .atomic)
        }

        let archive = workspace.appending(path: destination.lastPathComponent)
        try archiver.archive(directory: staging, to: archive)
        guard fileManager.fileExists(atPath: archive.path) else {
            throw BugReportError.couldNotWrite("the archiver produced no file")
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.replaceItemCore(at: destination, withItemAt: archive)
        } else {
            try fileManager.moveItem(at: archive, to: destination)
        }
    }

    private static func readme(generatedAt: Date, diagnostic: BugReportItem, toolSucceeded: Bool) -> String {
        var text = """
        \(AppIdentity.name) bug report
        Generated: \(generatedAt.formatted(.iso8601))

        Nothing in this folder has been sent anywhere. Attach it to your bug
        report only if you are comfortable sharing its contents.

        Contents:

        """
        for item in contents(diagnostic: diagnostic) {
            text += "- \(item.fileName): \(item.description)\n"
        }
        if !toolSucceeded {
            text += "\nNote: the USB/MTP diagnostic did not complete; see \(diagnostic.fileName).\n"
        }
        return text
    }
}

/// Links for reporting a problem. Centralised so the destination is changed in
/// one place.
public enum BugReportLinks {
    public static let issuesURL = AppIdentity.issuesURL

    /// A new-issue page prefilled with versions and a reminder to attach the zip.
    public static func newIssueURL(
        appVersion: String,
        macOSVersion: String,
        reportFileName: String = BugReportGenerator.defaultFileName
    ) -> URL {
        let body = """
        **Describe the problem**


        **Steps to reproduce**
        1.

        **Environment**
        - \(AppIdentity.name): \(appVersion)
        - macOS: \(macOSVersion)

        **Bug report**
        Please attach `\(reportFileName)` from your Desktop by dragging it into this box.
        """
        var components = URLComponents(
            url: issuesURL.appending(path: "new"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "body", value: body)
        ]
        return components.url ?? issuesURL
    }
}
