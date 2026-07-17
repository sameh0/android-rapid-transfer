import AppKit
import AndroidRapidTransferCore

/// The Dock tile's share of transfer feedback: a progress bar across the icon
/// while copies run, and, when a session finishes while the app is in the
/// background, one Dock bounce plus a badge counting anything that failed
/// (cleared when the user comes back).
@MainActor
final class DockProgressPresenter {
    static let shared = DockProgressPresenter()

    private var indicator: DockProgressIndicator?
    private var lastAppliedState: DockProgressState?
    private var activationObserver: NSObjectProtocol?

    private init() {}

    func apply(_ state: DockProgressState) {
        guard let application = NSApp else { return }
        guard state != lastAppliedState else { return }
        let indicator = indicator ?? makeIndicator(for: application)

        switch state {
        case .hidden:
            indicator.isHidden = true
        case .indeterminate:
            indicator.isHidden = false
            indicator.doubleValue = 0
        case let .determinate(value):
            indicator.isHidden = false
            indicator.isIndeterminate = false
            indicator.doubleValue = value
        }

        lastAppliedState = state
        application.dockTile.display()
    }

    /// Tells a user who switched away that the copy is done: the Dock icon
    /// bounces once, and a badge shows how many items need attention. Nothing
    /// happens while the app is frontmost; the panel already says it all.
    func announce(_ summary: TransferSessionSummary) {
        guard let application = NSApp, !application.isActive else { return }
        application.requestUserAttention(.informationalRequest)
        if summary.itemsFailed > 0 {
            application.dockTile.badgeLabel = summary.itemsFailed.formatted()
            clearBadgeOnActivation()
        }
    }

    private func clearBadgeOnActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp?.dockTile.badgeLabel = nil
            }
        }
    }

    private func makeIndicator(for application: NSApplication) -> DockProgressIndicator {
        let dockTile = application.dockTile
        let contentView = NSImageView()
        contentView.image = application.applicationIconImage
        contentView.imageScaling = .scaleProportionallyUpOrDown
        dockTile.contentView = contentView

        /// Use the dock tile width because a bare NSImageView stays zero-sized until layout.
        let tileWidth = dockTile.size.width > 0 ? dockTile.size.width : 128
        let inset = (tileWidth * 0.1).rounded()
        let indicator = DockProgressIndicator(
            frame: NSRect(x: inset, y: inset, width: tileWidth - inset * 2, height: (tileWidth * 0.11).rounded())
        )
        indicator.autoresizingMask = [.width, .maxYMargin]
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        contentView.addSubview(indicator)
        self.indicator = indicator
        return indicator
    }
}

/// A rounded bar in the system accent colour on a dark translucent track,
/// legible on any icon and in light or dark Dock.
private final class DockProgressIndicator: NSProgressIndicator {
    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden else { return }

        let trackRect = NSInsetRect(bounds, 0.5, 0.5)
        let radius = trackRect.height / 2
        let track = NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.45).setFill()
        track.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        track.lineWidth = 1
        track.stroke()

        let fillBounds = NSInsetRect(trackRect, 2, 2)
        let fraction = maxValue > 0 ? min(max(doubleValue / maxValue, 0), 1) : 0
        guard fraction > 0 else { return }
        let fillWidth = max(fillBounds.height, floor(fillBounds.width * fraction))
        let fillRect = NSRect(x: fillBounds.minX, y: fillBounds.minY, width: fillWidth, height: fillBounds.height)
        let fill = NSBezierPath(
            roundedRect: fillRect,
            xRadius: fillBounds.height / 2,
            yRadius: fillBounds.height / 2
        )
        NSColor.controlAccentColor.setFill()
        fill.fill()
    }
}
