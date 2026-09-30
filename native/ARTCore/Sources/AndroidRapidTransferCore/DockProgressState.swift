public enum DockProgressState: Equatable, Sendable {
    case hidden
    /// Work in flight, totals not yet known — rendered as an empty track,
    /// so a transfer that is still preparing never reads as complete.
    case indeterminate
    case determinate(Double)

    /// Maps aggregate transfer activity to a Dock progress state: absent work
    /// hides the bar, unknown totals are indeterminate, and known progress is
    /// clamped to the unit interval.
    public init(_ progress: TransferOverallProgress?) {
        guard let progress else {
            self = .hidden
            return
        }
        guard let percent = progress.percent else {
            self = .indeterminate
            return
        }
        self = .determinate(min(max(percent, 0), 1))
    }
}
