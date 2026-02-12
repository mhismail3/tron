import SwiftUI

/// Coordinates scroll state for chat views using `onScrollPhaseChange` (iOS 18+)
/// for definitive user-vs-programmatic scroll detection.
///
/// ## Architecture
///
/// Two independent input signals drive the state machine:
///
/// 1. **Phase signal** (`scrollPhaseChanged`) — tracks whether the user is physically
///    touching/flicking the scroll view. Phases `.interacting`, `.tracking`, and
///    `.decelerating` count as user interaction; `.animating` and `.idle` do not.
///
/// 2. **Geometry signal** (`geometryChanged`) — tracks whether the viewport is near
///    the bottom of the content. The threshold is computed in the view layer and
///    accounts for `contentInsets.bottom` (input bar + safe area).
///
/// The key invariant: **auto-scroll is suppressed whenever the user is interacting OR
/// has scrolled away.** This prevents programmatic `scrollTo` calls from fighting the
/// user's gesture during streaming.
///
/// A `hadUserInteraction` flag bridges the callback ordering race — `onScrollPhaseChange`
/// can fire before `onScrollGeometryChange` in the same frame, so the flag ensures a
/// geometry update arriving after phase → idle still correctly attributes the scroll to
/// the user.
@Observable
@available(iOS 18.0, *)
@MainActor
final class ScrollStateCoordinator {

    // MARK: - State

    /// Whether the viewport is near the bottom of the scroll content.
    private(set) var isAtBottom = true

    /// Whether the user has intentionally scrolled away from the bottom.
    /// Only set by user gestures (phase-based), never by programmatic scrolls.
    private(set) var userScrolledAway = false

    /// Whether new content arrived while the user was scrolled away.
    /// Drives the "New content" pill independently of processing state.
    private(set) var hasUnseenContent = false

    /// True while the user is physically interacting with the scroll view
    /// (touching, tracking, or decelerating from a flick).
    private var isUserInteracting = false

    /// Bridges the phase→geometry callback ordering race. Set when interaction
    /// starts, consumed by the next geometry update after interaction ends.
    private var hadUserInteraction = false

    // MARK: - History Loading

    private var anchoredItemId: UUID?

    // MARK: - Scroll Phase

    func scrollPhaseChanged(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        let wasUserInteracting = isUserInteracting
        isUserInteracting = newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating

        if isUserInteracting && !wasUserInteracting {
            hadUserInteraction = true
        }

        // When interaction ends not-at-bottom, mark scrolled away immediately.
        // Handles the case where the geometry Bool doesn't change during interaction
        // (e.g. user was already not-near-bottom when they started scrolling),
        // so onScrollGeometryChange never fires and geometryChanged is never called.
        if wasUserInteracting && !isUserInteracting && !isAtBottom {
            userScrolledAway = true
        }
    }

    // MARK: - Geometry Updates

    func geometryChanged(isNearBottom: Bool) {
        isAtBottom = isNearBottom

        // Attribute scroll-away to user if they're interacting or recently were.
        // hadUserInteraction is consumed (cleared) once used, preventing content
        // growth without user interaction from falsely setting userScrolledAway.
        if (isUserInteracting || hadUserInteraction) && !isNearBottom {
            userScrolledAway = true
            if !isUserInteracting {
                hadUserInteraction = false
            }
        }

        if isNearBottom {
            returnToBottom()
        }
    }

    // MARK: - Content Tracking

    /// Call when new content arrives (streaming text, new messages).
    /// Only marks unseen content if the user is actually scrolled away.
    func contentDidArrive() {
        if userScrolledAway {
            hasUnseenContent = true
        }
    }

    // MARK: - User Actions

    func userSentMessage() {
        returnToBottom()
    }

    func userTappedScrollToBottom() {
        returnToBottom()
    }

    // MARK: - History Loading

    func willPrependHistory(firstVisibleId: UUID?) {
        anchoredItemId = firstVisibleId
    }

    func didPrependHistory(using proxy: ScrollViewProxy?) {
        if let id = anchoredItemId {
            proxy?.scrollTo(id, anchor: .top)
            anchoredItemId = nil
        }
    }

    // MARK: - Navigation

    func scrollToTarget(messageId: UUID, using proxy: ScrollViewProxy?) {
        userScrolledAway = true
        hadUserInteraction = false
        withAnimation(.easeOut(duration: 0.3)) {
            proxy?.scrollTo(messageId, anchor: .center)
        }
    }

    // MARK: - Query

    var shouldAutoScroll: Bool {
        !userScrolledAway && !isUserInteracting
    }

    var shouldShowNewContentPill: Bool {
        userScrolledAway && hasUnseenContent
    }

    // MARK: - Private

    /// Resets all scroll-away state. Called when the user returns to the bottom
    /// by any means: scrolling back, tapping the pill, or sending a message.
    private func returnToBottom() {
        userScrolledAway = false
        hasUnseenContent = false
        hadUserInteraction = false
    }
}
