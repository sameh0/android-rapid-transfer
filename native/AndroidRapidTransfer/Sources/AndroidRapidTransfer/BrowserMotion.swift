import AndroidRapidTransferCore
import SwiftUI

/// Which way the user moved between two folders, so the listing can slide in
/// from the side the new folder lies on: deeper slides in from the trailing
/// edge, back up from the leading edge, and a jump elsewhere just fades.
enum BrowserNavigationDirection: Equatable {
    case forward
    case backward
    case lateral

    static func resolve(from oldLocation: String, to newLocation: String) -> Self {
        guard oldLocation != newLocation else { return .lateral }
        if isAncestor(oldLocation, of: newLocation) { return .forward }
        if isAncestor(newLocation, of: oldLocation) { return .backward }
        return .lateral
    }

    /// Where the incoming listing starts, in points along x.
    var entryOffset: CGFloat {
        switch self {
        case .forward: 28
        case .backward: -28
        case .lateral: 0
        }
    }

    private static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}

/// How a changed listing may animate. Folder switches get the directional
/// slide and the grid's cascade; changes within the same folder (a new
/// folder, a delete, a search narrowing, hidden files shown) animate item by
/// item, but only for listings small enough that doing so stays cheap.
enum BrowserListingAnimation {
    /// Above this many items, same-folder changes apply instantly.
    static let maxAnimatedItems = 300

    static func animatesChanges(
        displayedLocation: String,
        location: String,
        itemCount: Int,
        reduceMotion: Bool
    ) -> Bool {
        !reduceMotion && displayedLocation == location && itemCount <= maxAnimatedItems
    }
}

/// The staggered fade-in of the first grid items when a folder opens. Only
/// the first ``maxItems`` animate, and only right after the listing arrives,
/// so scrolling back to the top later does not replay it.
enum BrowserCascade {
    static let maxItems = 30
    /// Delay between neighbouring items.
    static let step: TimeInterval = 0.012
    /// How long after a listing appears an item may still cascade in.
    static let window: TimeInterval = 0.5

    /// The delay before item `index` fades in, or nil when it should just be
    /// there (too far down, too late, or Reduce Motion).
    static func delay(
        forIndex index: Int,
        elapsedSinceListing elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> TimeInterval? {
        guard !reduceMotion, index >= 0, index < maxItems, elapsed < window else { return nil }
        return Double(index) * step
    }
}

/// An item to draw the eye to once it lands in the listing: a folder the user
/// just created, or an item they just renamed. `revision` replays the effect
/// when the same item is highlighted twice.
struct BrowserEntryHighlight: Equatable {
    let entryID: BrowserEntry.ID
    let revision: Int
}

extension View {
    /// Slides the listing in from the direction of travel when `location`
    /// changes. One view moves, whatever the folder holds.
    func browserNavigationSlide(
        location: String,
        direction: BrowserNavigationDirection
    ) -> some View {
        modifier(BrowserNavigationSlideModifier(location: location, direction: direction))
    }
}

private struct BrowserSlideState {
    var offset: CGFloat = 0
    var opacity: Double = 1
}

private struct BrowserNavigationSlideModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let location: String
    let direction: BrowserNavigationDirection

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(
                initialValue: BrowserSlideState(),
                trigger: location
            ) { content, state in
                content
                    .offset(x: state.offset)
                    .opacity(state.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.offset) {
                    MoveKeyframe(direction.entryOffset)
                    SpringKeyframe(0, duration: Motion.Duration.standard, spring: .snappy)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0.35)
                    CubicKeyframe(1, duration: Motion.Duration.quick)
                }
            }
        }
    }
}
