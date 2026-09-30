import Foundation
import Observation

/// Drives the "Copy by Date Range" sheet: date entry, the cancellable scan, and
/// the reviewable preview that precedes the transfer.
///
/// The scan itself lives in ``DeviceFolderScanner``; this type owns only the
/// sheet's state machine so the traversal stays testable on its own.
@MainActor
@Observable
public final class DateRangeCopyViewModel: Identifiable {
    /// What the user asked for when they started a scan. `copyNow` skips the
    /// preview and hands the plan straight to the caller once the walk finishes.
    public enum Intent: Equatable, Sendable {
        case preview
        case copyNow
    }

    public enum Phase: Equatable, Sendable {
        case configuring
        case scanning(DateRangeScanProgress)
        case reviewing
    }

    public private(set) var phase: Phase = .configuring
    public var startDate: Date
    public var endDate: Date
    /// When `false` the range runs "until now" and ``endDate`` is ignored.
    public var hasEndDate: Bool
    /// Skip dot-prefixed entries during the scan. Plain sheet state like the
    /// dates above — none of the sheet's inputs are persisted, and a scan-scope
    /// choice that silently carried over from a previous launch could quietly
    /// hide files the user expects to see.
    public var ignoreDotFiles = false
    /// Skip cache-typical entries during the scan; see ``ScanExclusionRules``
    /// for the exact heuristic. Deliberately not persisted, same as above.
    public var ignoreCacheFiles = false
    /// Extensions currently checked in this presentation of the sheet.
    /// `.cnt` starts checked by design, so every scan skips it unless the user
    /// explicitly unchecks it. This state is not persisted.
    public var ignoredExtensions: Set<String> = [".cnt"]
    /// Text being edited in the custom-extension field.
    public var customExtensionInput = ""
    /// Normalized custom extensions, kept in insertion order for the sheet.
    public private(set) var customExtensions: [String] = []
    public private(set) var result: DateRangeScanResult?
    /// Directory currently being read, including advisory native listing progress.
    public private(set) var currentListing: DirectoryListingProgress?
    /// Matches found so far, used only while the scan is still in progress.
    public private(set) var streamedMatches: [DateRangeMatch] = []
    /// Matches the user deselected in the preview, keyed by device path.
    public private(set) var excludedMatchIDs: Set<String> = []

    /// The device folders the scan will walk, in selection order.
    public let roots: [String]
    /// Where the copy will land. The sheet starts with the resolved default and
    /// lets the user replace it before copying.
    public var destination: String

    @ObservationIgnored private let scanner: DeviceFolderScanner
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let copy: (DateRangeCopyPlan, String) -> Void
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// Built-in extension choices in their sheet display order.
    public static let presetExtensions = [".cnt", ".nomedia", ".log", ".bak"]

    public init(
        roots: [String],
        destination: String,
        scanner: DeviceFolderScanner,
        calendar: Calendar = .current,
        now: Date = Date(),
        copy: @escaping (DateRangeCopyPlan, String) -> Void
    ) {
        self.roots = roots
        self.destination = destination
        self.scanner = scanner
        self.calendar = calendar
        self.copy = copy
        // A week back is a useful default for the "what did I shoot recently"
        // case without pretending to know the user's intent.
        startDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        endDate = now
        hasEndDate = false
    }

    deinit {
        scanTask?.cancel()
    }

    /// The window described by the current form values.
    public var filter: DateRangeFilter {
        DateRangeFilter.calendarDays(
            from: startDate,
            through: hasEndDate ? endDate : nil,
            in: calendar
        )
    }

    /// The scan-time exclusions described by the sheet controls.
    public var exclusionRules: ScanExclusionRules {
        ScanExclusionRules(
            ignoresDotFiles: ignoreDotFiles,
            ignoresCacheFiles: ignoreCacheFiles,
            ignoredExtensions: ignoredExtensions
        )
    }

    /// Presets followed by user-added extensions, ready for checkbox rendering.
    public var extensionOptions: [String] {
        Self.presetExtensions + customExtensions
    }

    public var canAddCustomExtension: Bool {
        Self.normalizeExtension(customExtensionInput) != nil
    }

    /// Trims surrounding whitespace, lowercases, and replaces any number of
    /// leading dots with exactly one. Empty values and dot-only values are invalid.
    public static func normalizeExtension(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.drop(while: { $0 == "." })
        guard !suffix.isEmpty else { return nil }
        return "." + suffix.lowercased()
    }

    public func isIgnoringExtension(_ fileExtension: String) -> Bool {
        guard let normalized = Self.normalizeExtension(fileExtension) else { return false }
        return ignoredExtensions.contains(normalized)
    }

    public func setIgnoringExtension(_ ignored: Bool, fileExtension: String) {
        guard let normalized = Self.normalizeExtension(fileExtension) else { return }
        if ignored {
            ignoredExtensions.insert(normalized)
        } else {
            ignoredExtensions.remove(normalized)
        }
    }

    /// Adds the current text-field value, checking an existing preset rather
    /// than creating a duplicate custom row.
    public func addCustomExtension() {
        guard let normalized = Self.normalizeExtension(customExtensionInput) else { return }
        customExtensionInput = ""
        ignoredExtensions.insert(normalized)
        if !Self.presetExtensions.contains(normalized),
           !customExtensions.contains(normalized) {
            customExtensions.append(normalized)
        }
    }

    public func removeCustomExtension(_ fileExtension: String) {
        guard let normalized = Self.normalizeExtension(fileExtension),
              !Self.presetExtensions.contains(normalized)
        else { return }
        customExtensions.removeAll { $0 == normalized }
        ignoredExtensions.remove(normalized)
    }

    public var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    public var canStartScan: Bool {
        !roots.isEmpty && filter.isValid && !isScanning
    }

    /// Matches still ticked in the preview, in scan order.
    public var selectedMatches: [DateRangeMatch] {
        (result?.matches ?? []).filter { !excludedMatchIDs.contains($0.id) }
    }

    public var selectedFileCount: Int { selectedMatches.count }

    public var selectedTotalSize: Int64 {
        selectedMatches.reduce(0) { $0 + $1.size }
    }

    public var canCopySelection: Bool { !isScanning && !selectedMatches.isEmpty }

    public func isIncluded(_ match: DateRangeMatch) -> Bool {
        !excludedMatchIDs.contains(match.id)
    }

    public func setIncluded(_ included: Bool, for match: DateRangeMatch) {
        if included {
            excludedMatchIDs.remove(match.id)
        } else {
            excludedMatchIDs.insert(match.id)
        }
    }

    /// Runs the scan, then either delivers the plan (`copyNow`) or shows the
    /// preview. A `copyNow` scan that matched nothing still falls through to the
    /// preview so the empty result is explained rather than silently doing nothing.
    public func startScan(intent: Intent) {
        guard canStartScan else { return }
        scanTask?.cancel()
        excludedMatchIDs = []
        currentListing = nil
        streamedMatches = []
        result = nil
        phase = .scanning(
            DateRangeScanProgress(scannedFolders: 0, matchedFiles: 0, currentPath: "")
        )

        let filter = filter
        let exclusions = exclusionRules
        scanTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await scanner.scan(
                roots: roots,
                filter: filter,
                exclusions: exclusions,
                onMatch: { matches in
                    guard !Task.isCancelled else { return }
                    self.streamedMatches.append(contentsOf: matches)
                },
                onProgress: { progress in
                    guard !Task.isCancelled else { return }
                    self.phase = .scanning(progress)
                },
                onListing: { listing in
                    guard !Task.isCancelled, self.isScanning else { return }
                    self.currentListing = listing
                }
            )
            guard !Task.isCancelled else { return }
            finishScan(outcome, intent: intent)
        }
    }

    /// Abandons an in-flight scan and returns to the form. Partial results are
    /// discarded because a truncated match list would misrepresent the range.
    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        currentListing = nil
        streamedMatches = []
        result = nil
        phase = .configuring
    }

    /// Returns to the form so the user can widen or narrow the range.
    public func editRange() {
        scanTask?.cancel()
        scanTask = nil
        currentListing = nil
        streamedMatches = []
        phase = .configuring
    }

    /// Hands the still-selected matches to the caller as a transfer plan.
    public func copySelection() {
        guard canCopySelection else { return }
        copy(DateRangeCopyPlan(matches: selectedMatches), destination)
    }

    private func finishScan(_ outcome: DateRangeScanResult, intent: Intent) {
        scanTask = nil
        currentListing = nil
        result = outcome
        phase = .reviewing
        if intent == .copyNow, !outcome.isEmpty {
            copySelection()
        }
    }
}
