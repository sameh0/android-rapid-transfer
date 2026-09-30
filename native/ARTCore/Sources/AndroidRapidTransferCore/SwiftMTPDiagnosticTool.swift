import Foundation
import SwiftMTP

/// The bug-report diagnostic: ``SwiftMTPDiagnostics`` run
/// in-process on a background thread, bounded by a timeout. The device-facing
/// work is injected, so tests never touch USB.
public struct SwiftMTPDiagnosticTool: DebugToolRunning {
    public typealias Diagnose = @Sendable (SwiftMTPDiagnosticsCancellation) -> SwiftMTPDiagnosticReport

    public static let name = "SwiftMTP"
    /// Longer than the diagnostic's own time budget, which normally ends it first.
    public static let defaultTimeout: Duration = .seconds(60)
    /// After a timeout the diagnostic is cancelled, which releases the
    /// interface; a blocked transfer then ends within one bulk timeout.
    public static let defaultCancellationGrace: Duration = .seconds(10)

    private let timeout: Duration
    private let cancellationGrace: Duration
    private let diagnose: Diagnose

    public init(
        timeout: Duration = defaultTimeout,
        cancellationGrace: Duration = defaultCancellationGrace,
        diagnose: @escaping Diagnose = { SwiftMTPDiagnostics.run(cancellation: $0) }
    ) {
        self.timeout = timeout
        self.cancellationGrace = cancellationGrace
        self.diagnose = diagnose
    }

    public var reportItem: BugReportItem { .deviceDiagnostic }

    public func run() async -> DebugToolResult {
        let cancellation = SwiftMTPDiagnosticsCancellation()
        let result = DiagnosticResultBox()
        let diagnose = diagnose
        // Blocking USB I/O: a thread of its own, never the cooperative pool.
        Thread.detachNewThread {
            result.fulfill(diagnose(cancellation))
        }

        if let report = await result.wait(for: timeout) {
            return DebugToolResult(
                name: Self.name,
                report: report.text,
                termination: report.completed ? .completed : .incomplete
            )
        }

        // cancel() can block for up to one bulk timeout while it closes the pipe.
        DispatchQueue.global(qos: .userInitiated).async { cancellation.cancel() }
        let late = await result.wait(for: cancellationGrace)
        return DebugToolResult(
            name: Self.name,
            report: late?.text,
            termination: .timedOut(seconds: Int(timeout.components.seconds))
        )
    }
}

/// A one-shot result that can be awaited with a time limit.
final class DiagnosticResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: SwiftMTPDiagnosticReport?
    private var waiters: [UUID: CheckedContinuation<SwiftMTPDiagnosticReport?, Never>] = [:]

    func fulfill(_ report: SwiftMTPDiagnosticReport) {
        let pending: [CheckedContinuation<SwiftMTPDiagnosticReport?, Never>] = lock.withLock {
            guard result == nil else { return [] }
            result = report
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in pending { waiter.resume(returning: report) }
    }

    /// The result, or nil when it did not arrive within `duration`.
    func wait(for duration: Duration) async -> SwiftMTPDiagnosticReport? {
        let first = await withTaskGroup(of: SwiftMTPDiagnosticReport?.self) { group in
            group.addTask { await self.next() }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return first ?? lock.withLock { result }
    }

    private func next() async -> SwiftMTPDiagnosticReport? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: SwiftMTPDiagnosticReport?? = lock.withLock {
                    if let result { return .some(result) }
                    if Task.isCancelled { return .some(nil) }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(returning: nil)
        }
    }
}
