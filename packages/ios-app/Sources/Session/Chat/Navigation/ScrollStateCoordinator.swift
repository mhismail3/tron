import SwiftUI

/// Coordinates scroll state for chat views using `onScrollPhaseChange`
/// for definitive user-vs-programmatic scroll detection.
///
/// ## Architecture
///
/// Two independent input signals drive the state machine:
///
/// 1. **Phase signal** (`scrollPhaseChanged`) — tracks whether the user is physically
///    touching/flicking the scroll view and whether the scroll view is still
///    settling. Phases `.interacting`, `.tracking`, and `.decelerating` count as
///    user interaction; `.animating` is not user intent, but it still suppresses
///    new programmatic bottom scrolls until the rebound/programmatic animation ends.
///
/// 2. **Geometry signal** (`geometryChanged`) — tracks whether the viewport is near
///    the bottom of the content. The threshold is computed in the view layer and
///    accounts for `contentInsets.bottom` (input bar + safe area).
///
/// Earlier-history loading has two paths:
///
/// - **Eager prefetch** when a real user gesture leaves the bottom. This keeps older
///   history warm before the user hits the loaded boundary.
/// - **Top-detent load** from view-layer top geometry. This is the boundary backup and
///   does not depend on `userScrolledAway`, because SwiftUI can report "near top"
///   before phase/bottom callbacks have settled.
///
/// Eager prefetch is one-shot per scroll-away interval. The interval resets only when
/// the viewport returns to bottom, which prevents phase and geometry callbacks from
/// requesting multiple pages for a single drag.
///
/// The key invariant: **auto-scroll is suppressed whenever the user is interacting,
/// the scroll view is settling, history is being prepended, OR the user has scrolled
/// away.** This prevents programmatic `scrollTo` calls from fighting live gestures,
/// rubber-band rebound, lazy-stack anchor restoration, or streaming updates.
///
/// A `hadUserInteraction` flag covers the callback ordering race — `onScrollPhaseChange`
/// can fire before `onScrollGeometryChange` in the same frame, so the flag ensures a
/// geometry update arriving after phase → idle still correctly attributes the scroll to
/// the user.
@Observable
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

    /// Whether the current away-from-bottom interval already requested an eager
    /// earlier-history page.
    private var didPrefetchEarlierHistoryDuringScrollAway = false

    /// True while the user is physically interacting with the scroll view
    /// (touching, tracking, or decelerating from a flick).
    private var isUserInteracting = false

    /// True while SwiftUI reports an animation phase for either a programmatic
    /// scroll or a rubber-band rebound. It is not user intent, but it is still
    /// an unstable interval where additional bottom scrolls can cause jumps.
    private var isScrollSettling = false

    /// Bridges the phase→geometry callback ordering race. Set when interaction
    /// starts, consumed by the next geometry update after interaction ends.
    private var hadUserInteraction = false

    // MARK: - History Loading

    /// Suppresses scroll-away detection during history prepend.
    /// Prepending shifts the viewport away from bottom; without this guard,
    /// the "New content" pill would flash while older rows are inserted.
    var isPrependingHistory = false

    private var prependAnchor: ScrollViewportAnchor?
    private var targetNavigationSnapshot: TargetNavigationSnapshot?

    // MARK: - Scroll Phase

    func scrollPhaseChanged(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        let wasUserInteracting = isUserInteracting
        isUserInteracting = newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating
        isScrollSettling = newPhase == .animating

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
        guard !isPrependingHistory else { return }
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

    func beginTargetNavigation() {
        targetNavigationSnapshot = TargetNavigationSnapshot(
            userScrolledAway: userScrolledAway,
            hasUnseenContent: hasUnseenContent,
            hadUserInteraction: hadUserInteraction,
            isPrependingHistory: isPrependingHistory
        )
        userScrolledAway = true
        hasUnseenContent = false
        hadUserInteraction = false
        isPrependingHistory = true
    }

    func endTargetNavigation(foundTarget: Bool = true) {
        defer { targetNavigationSnapshot = nil }

        guard foundTarget else {
            if let snapshot = targetNavigationSnapshot {
                userScrolledAway = snapshot.userScrolledAway
                hasUnseenContent = snapshot.hasUnseenContent
                hadUserInteraction = snapshot.hadUserInteraction
                isPrependingHistory = snapshot.isPrependingHistory
            } else {
                isPrependingHistory = false
                hasUnseenContent = false
            }
            return
        }

        isPrependingHistory = false
        hasUnseenContent = false
    }

    // MARK: - History Loading

    func willPrependHistory(anchor: ScrollViewportAnchor?) {
        prependAnchor = anchor
        isPrependingHistory = true
    }

    func didPrependHistory(using proxy: ScrollViewProxy?) {
        if let anchor = prependAnchor {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy?.scrollTo(anchor.messageId, anchor: .top)
            }
            prependAnchor = nil
        }
        isPrependingHistory = false
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
        !userScrolledAway && !isUserInteracting && !isScrollSettling && !isPrependingHistory
    }

    var shouldShowNewContentPill: Bool {
        userScrolledAway && hasUnseenContent
    }

    func shouldAutoloadEarlierMessages(
        hasMoreMessages: Bool,
        initialLoadComplete: Bool,
        isLoadingMoreMessages: Bool,
        isNearTop: Bool
    ) -> Bool {
        hasMoreMessages
            && initialLoadComplete
            && isNearTop
            && !isLoadingMoreMessages
            && !isPrependingHistory
    }

    func shouldPrefetchEarlierMessages(
        hasMoreMessages: Bool,
        initialLoadComplete: Bool,
        isLoadingMoreMessages: Bool
    ) -> Bool {
        hasMoreMessages
            && initialLoadComplete
            && userScrolledAway
            && !isLoadingMoreMessages
            && !isPrependingHistory
            && !didPrefetchEarlierHistoryDuringScrollAway
    }

    func beginEarlierHistoryPrefetchIfNeeded(
        hasMoreMessages: Bool,
        initialLoadComplete: Bool,
        isLoadingMoreMessages: Bool
    ) -> Bool {
        guard shouldPrefetchEarlierMessages(
            hasMoreMessages: hasMoreMessages,
            initialLoadComplete: initialLoadComplete,
            isLoadingMoreMessages: isLoadingMoreMessages
        ) else {
            return false
        }

        didPrefetchEarlierHistoryDuringScrollAway = true
        return true
    }

    // MARK: - Private

    /// Resets all scroll-away state. Called when the user returns to the bottom
    /// by any means: scrolling back, tapping the pill, or sending a message.
    private func returnToBottom() {
        userScrolledAway = false
        hasUnseenContent = false
        hadUserInteraction = false
        didPrefetchEarlierHistoryDuringScrollAway = false
    }

    private struct TargetNavigationSnapshot {
        let userScrolledAway: Bool
        let hasUnseenContent: Bool
        let hadUserInteraction: Bool
        let isPrependingHistory: Bool
    }
}
