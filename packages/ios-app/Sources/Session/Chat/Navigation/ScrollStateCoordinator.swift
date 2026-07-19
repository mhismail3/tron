import SwiftUI

/// Coordinates chat scroll state from native ownership, phase, and geometry signals.
///
/// ## Architecture
///
/// Three input signals drive the state machine:
///
/// 1. **Phase signal** (`scrollPhaseChanged`) — tracks whether the user is physically
///    touching/flicking the scroll view and whether the scroll view is still
///    settling. Phases `.interacting`, `.tracking`, and `.decelerating` count as
///    user interaction. An `.animating` phase entered from user interaction is a
///    rebound and suppresses bottom scrolling until it ends; a programmatic bottom
///    animation remains eligible so live content can keep following the moving edge.
///
/// 2. **Native ownership signal** (`scrollPositionChanged`) — reads
///    `ScrollPosition.isPositionedByUser`, which covers touch, pointer, and native
///    positioning paths even when SwiftUI animates directly from idle.
///
/// 3. **Geometry signal** (`geometryChanged`) — tracks whether the viewport is near
///    the bottom and accumulates stable movement toward older content. This fallback
///    covers accessibility and indirect scrolling on runtimes that publish neither a
///    phase nor native ownership. The coordinator owns the attribution threshold; the
///    view supplies bottom distance including `contentInsets.bottom` (input bar + safe
///    area).
///
/// Earlier-history loading is owned by the view-layer top-detent geometry.
/// Leaving the bottom is not enough to mutate the message array: a fast upward
/// flick can cover a large distance after the first scroll-away callback, so
/// prepending from that early callback would restore a stale anchor and snap the
/// user back down. The top-detent path waits until the loaded-history boundary is
/// close enough to matter, then captures the current viewport anchor immediately
/// before prepending.
///
/// The key invariant: **bottom auto-scroll is suppressed whenever native user
/// ownership or its pending geometry is active, the user is interacting, a
/// user-driven rebound is settling, history is being prepended, OR the user has
/// scrolled away.** Programmatic settling alone must not disable a pinned transcript
/// because a suspended animation may never report a later idle phase. Earlier-history
/// autoload still waits for every settling animation.
/// Foreground activation clears only transient phase attribution; durable scroll-away,
/// unseen-content, prepend, and target-navigation state remain authoritative.
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
    /// Set by native ownership/geometry or direct gesture phases, never by app scrolls.
    private(set) var userScrolledAway = false

    /// Whether new content arrived while the user was scrolled away.
    /// Drives the "New content" pill independently of processing state.
    private(set) var hasUnseenContent = false

    /// True while the user is physically interacting with the scroll view
    /// (touching, tracking, or decelerating from a flick).
    private var isUserInteracting = false

    /// True while SwiftUI reports an animation phase for either a programmatic
    /// scroll or a rubber-band rebound. It is not user intent, but it is still
    /// an unstable interval where additional bottom scrolls can cause jumps.
    private var isScrollSettling = false

    /// True only when the current animation continues a user-driven phase. Unlike
    /// programmatic bottom animation, this rebound must not fight a live gesture.
    private var isUserDrivenSettling = false

    /// SwiftUI's authoritative ownership bit for touch, pointer, and native user
    /// positioning. App-issued positioning explicitly clears this ownership.
    private var isScrollPositionedByUser = false

    /// Bridges native ownership ending before its final geometry callback, just as
    /// `hadUserInteraction` bridges the touch phase→geometry ordering race.
    private var hasPendingNativeUserGeometry = false

    /// Records whether the current idle→scroll activity epoch has produced geometry
    /// while the bound `ScrollPosition` was user-owned. App-animation geometry cannot
    /// satisfy a later native takeover.
    private var hasObservedNativeUserGeometryInCurrentScrollActivity = false

    /// Bridges the phase→geometry callback ordering race. Set when interaction
    /// starts, consumed by the next geometry update after interaction ends.
    private var hadUserInteraction = false

    /// Consecutive stable geometry-only movement toward older content. The first
    /// sample pauses bottom ownership; only cumulative page-scale movement commits
    /// durable scroll-away intent.
    private var pendingGeometryOnlyOlderMovement: CGFloat = 0
    private var geometryOnlyAutoscrollVetoArmed = false
    private var pendingGeometryOnlyHasUnseenContent = false

    // MARK: - History Loading

    /// Suppresses scroll-away detection during history prepend.
    /// Prepending shifts the viewport away from bottom; without this guard,
    /// the "New content" pill would flash while older rows are inserted.
    var isPrependingHistory = false

    private var prependAnchor: ScrollViewportAnchor?
    private var targetNavigationSnapshot: TargetNavigationSnapshot?

    // MARK: - Scroll Phase

    func scrollPhaseChanged(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        finalIsNearBottom: Bool? = nil
    ) {
        if oldPhase == .idle && newPhase != .idle {
            hasObservedNativeUserGeometryInCurrentScrollActivity = false
        }

        // ScrollPhaseChangeContext carries the phase transition's authoritative
        // geometry snapshot. Resolve it before clearing interaction/native state
        // so a geometry callback delivered after phase → idle cannot lose its
        // user attribution.
        if newPhase == .idle, let finalIsNearBottom {
            geometryChanged(isNearBottom: finalIsNearBottom)
        }

        let wasUserInteracting = isUserInteracting
        let wasUserDrivenSettling = isUserDrivenSettling
        isUserInteracting = newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating
        isScrollSettling = newPhase == .animating
        isUserDrivenSettling = isScrollSettling
            && (wasUserDrivenSettling || Self.isUserDrivenPhase(oldPhase))

        if isUserInteracting && !wasUserInteracting {
            hadUserInteraction = true
        }

        // When interaction ends not-at-bottom, mark scrolled away immediately.
        // Handles the case where the geometry Bool doesn't change during interaction
        // (e.g. user was already not-near-bottom when they started scrolling),
        // so onScrollGeometryChange never fires and geometryChanged is never called.
        if wasUserInteracting && !isUserInteracting && !isAtBottom {
            userScrolledAway = true
            commitPendingGeometryOnlyContent()
        }

        if newPhase == .idle && isAtBottom && !hasPendingNativeUserGeometry {
            // Geometry can arrive after idle. Release only native ownership here;
            // keep hadUserInteraction so a late away geometry sample still commits
            // the gesture instead of being mistaken for streamed content growth.
            isScrollPositionedByUser = false
        }
    }

    /// Updates native scroll ownership. Geometry and ownership callbacks can arrive
    /// in either order, so an already-away viewport is committed immediately while
    /// a bottom-originating gesture blocks auto-scroll until geometry follows.
    func scrollPositionChanged(isPositionedByUser: Bool) {
        let ownershipTransferredToUser = isPositionedByUser && !isScrollPositionedByUser
        isScrollPositionedByUser = isPositionedByUser
        if isPositionedByUser {
            if isScrollSettling {
                isUserDrivenSettling = true
            }
            if ownershipTransferredToUser {
                hasObservedNativeUserGeometryInCurrentScrollActivity = false
            }
            hasPendingNativeUserGeometry = !hasObservedNativeUserGeometryInCurrentScrollActivity
            if !isAtBottom {
                userScrolledAway = true
                commitPendingGeometryOnlyContent()
                hasPendingNativeUserGeometry = false
            }
        }
    }

    /// Explicit app positioning takes ownership synchronously. Binding callbacks
    /// that merely report `false` do not clear pending late user geometry.
    func appWillPositionScroll() {
        resetPendingGeometryOnlyMovement()
        isScrollPositionedByUser = false
        hasPendingNativeUserGeometry = false
        hasObservedNativeUserGeometryInCurrentScrollActivity = false
        isUserDrivenSettling = false
    }

    /// Clears phase state that cannot remain authoritative while the app is inactive.
    /// Intentional viewport state and in-flight navigation/history ownership survive.
    func sceneDidBecomeActive(isPositionedByUser: Bool = false) {
        if hasPendingGeometryOnlyMovement && !isAtBottom {
            userScrolledAway = true
            commitPendingGeometryOnlyContent()
        } else {
            resetPendingGeometryOnlyMovement()
        }
        isUserInteracting = false
        isScrollSettling = false
        isUserDrivenSettling = false
        hadUserInteraction = false
        hasObservedNativeUserGeometryInCurrentScrollActivity = false
        isScrollPositionedByUser = isPositionedByUser
        hasPendingNativeUserGeometry = isPositionedByUser
        if isPositionedByUser {
            if !isAtBottom {
                userScrolledAway = true
                hasPendingNativeUserGeometry = false
            }
        }
        if let snapshot = targetNavigationSnapshot {
            targetNavigationSnapshot = TargetNavigationSnapshot(
                userScrolledAway: snapshot.userScrolledAway,
                hasUnseenContent: snapshot.hasUnseenContent,
                hadUserInteraction: false,
                isPrependingHistory: snapshot.isPrependingHistory
            )
        }
    }

    // MARK: - Geometry Updates

    @discardableResult
    func geometryChanged(
        isNearBottom: Bool,
        geometryOnlyMovement: GeometryOnlyMovement = .preserve
    ) -> Bool {
        let hadPendingNativeUserGeometry = hasPendingNativeUserGeometry
        if isScrollPositionedByUser {
            hasObservedNativeUserGeometryInCurrentScrollActivity = true
        }
        if isScrollPositionedByUser || hadPendingNativeUserGeometry {
            hasPendingNativeUserGeometry = false
        }

        if isAtBottom != isNearBottom {
            isAtBottom = isNearBottom
        }

        let hasDirectUserAttribution = isUserInteracting
            || hadUserInteraction
            || isUserDrivenSettling
            || isScrollPositionedByUser
            || hadPendingNativeUserGeometry
        let committedGeometryOnlyMovement = hasDirectUserAttribution
            ? false
            : applyGeometryOnlyMovement(
                geometryOnlyMovement,
                isNearBottom: isNearBottom
            )

        // Attribute scroll-away to direct interaction, its late geometry callback,
        // native user ownership, cumulative geometry-only accessibility movement, or a
        // user-driven animation whose ownership bit cleared just before the phase
        // transition's final geometry snapshot. History prepend owns its geometry
        // shifts, so those must never manufacture user intent.
        if (hasDirectUserAttribution || committedGeometryOnlyMovement)
            && !isNearBottom {
            userScrolledAway = true
            commitPendingGeometryOnlyContent()
            hasPendingNativeUserGeometry = false
            if !isUserInteracting {
                hadUserInteraction = false
            }
        }

        if isNearBottom {
            if !hasDirectUserAttribution && geometryOnlyMovement.preservesPendingCandidate {
                clearDurableScrollAwayState()
            } else {
                clearScrollAwayState()
            }
            if shouldReleaseNativeScrollOwnership {
                isScrollPositionedByUser = false
                hasPendingNativeUserGeometry = false
            }
        }

        return committedGeometryOnlyMovement
    }

    // MARK: - Content Tracking

    /// Call when new content arrives (streaming text, new messages).
    /// Only marks unseen content if the user is actually scrolled away.
    func contentDidArrive() {
        guard !isPrependingHistory else { return }
        if userScrolledAway {
            hasUnseenContent = true
        } else if hasPendingGeometryOnlyMovement {
            pendingGeometryOnlyHasUnseenContent = true
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
        resetPendingGeometryOnlyMovement()
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
        resetPendingGeometryOnlyMovement()
        prependAnchor = anchor
        isPrependingHistory = true
    }

    func cancelPrependHistory() {
        prependAnchor = nil
        isPrependingHistory = false
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
        resetPendingGeometryOnlyMovement()
        userScrolledAway = true
        hadUserInteraction = false
        withAnimation(.easeOut(duration: 0.3)) {
            proxy?.scrollTo(messageId, anchor: .center)
        }
    }

    // MARK: - Query

    var shouldAutoScroll: Bool {
        isEligibleForAutomaticScroll
            && !geometryOnlyAutoscrollVetoArmed
    }

    /// Atomically grants app ownership for an automatic bottom movement. A
    /// sub-threshold indirect movement vetoes one request; another movement sample
    /// re-arms the veto, while a second request with no movement safely resumes.
    func beginAutomaticBottomScroll() -> Bool {
        guard isEligibleForAutomaticScroll else { return false }
        if geometryOnlyAutoscrollVetoArmed {
            geometryOnlyAutoscrollVetoArmed = false
            return false
        }
        appWillPositionScroll()
        return true
    }

    private var isEligibleForAutomaticScroll: Bool {
        !userScrolledAway
            && !isUserInteracting
            && !isUserDrivenSettling
            && !isScrollPositionedByUser
            && !hasPendingNativeUserGeometry
            && !isPrependingHistory
    }

    var shouldShowNewContentPill: Bool {
        userScrolledAway && hasUnseenContent
    }

    /// Classifies one geometry-only movement sample without relying on phase or
    /// native ownership callbacks. Matching movement away from the bottom
    /// distinguishes viewport motion from stationary streamed growth, while stable
    /// viewport and inset geometry reject keyboard, rotation, and composer shifts.
    /// Consecutive `.towardOlderContent` samples are accumulated by the coordinator.
    static func classifyGeometryOnlyMovement(
        oldContentOffsetY: CGFloat,
        newContentOffsetY: CGFloat,
        oldDistanceFromBottom: CGFloat,
        newDistanceFromBottom: CGFloat,
        oldViewportHeight: CGFloat,
        newViewportHeight: CGFloat,
        oldBottomInset: CGFloat,
        newBottomInset: CGFloat
    ) -> GeometryOnlyMovement {
        guard oldContentOffsetY.isFinite,
              newContentOffsetY.isFinite,
              oldDistanceFromBottom.isFinite,
              newDistanceFromBottom.isFinite,
              oldViewportHeight.isFinite,
              newViewportHeight.isFinite,
              oldBottomInset.isFinite,
              newBottomInset.isFinite,
              oldViewportHeight > 0,
              newViewportHeight > 0,
              abs(oldViewportHeight - newViewportHeight) <= 1,
              abs(oldBottomInset - newBottomInset) <= 1 else {
            return .reset
        }

        let offsetMovement = oldContentOffsetY - newContentOffsetY
        let bottomMovement = newDistanceFromBottom - oldDistanceFromBottom
        if abs(offsetMovement) <= 1, bottomMovement > 1 {
            return .stationaryContentGrowth
        }
        guard offsetMovement > 1, bottomMovement > 1 else {
            return .reset
        }
        return .towardOlderContent(
            distance: min(offsetMovement, bottomMovement),
            threshold: min(
                max(64, newViewportHeight * 0.2),
                ChatTranscriptRevealPolicy.autoscrollBottomTolerance
            )
        )
    }

    enum GeometryOnlyMovement: Equatable {
        case towardOlderContent(distance: CGFloat, threshold: CGFloat)
        case stationaryContentGrowth
        /// No geometry sample was available, so existing evidence remains valid.
        case preserve
        case reset

        fileprivate var preservesPendingCandidate: Bool {
            switch self {
            case .towardOlderContent, .stationaryContentGrowth, .preserve:
                true
            case .reset:
                false
            }
        }
    }

    /// Native ownership can be released without moving the viewport only after a
    /// bottom-positioned gesture or native user animation has fully settled.
    var shouldReleaseNativeScrollOwnership: Bool {
        isAtBottom
            && !isUserInteracting
            && !isScrollSettling
            && !isUserDrivenSettling
            && !hasPendingNativeUserGeometry
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
            && !isUserInteracting
            && !isScrollSettling
    }

    // MARK: - Private

    /// Resets all scroll-away state. Called when the user returns to the bottom
    /// by any means: scrolling back, tapping the pill, or sending a message.
    private func returnToBottom() {
        clearScrollAwayState()
        isScrollPositionedByUser = false
        hasPendingNativeUserGeometry = false
        hasObservedNativeUserGeometryInCurrentScrollActivity = false
        isUserDrivenSettling = false
    }

    private func clearScrollAwayState() {
        resetPendingGeometryOnlyMovement()
        clearDurableScrollAwayState()
    }

    private func clearDurableScrollAwayState() {
        if userScrolledAway {
            userScrolledAway = false
        }
        if hasUnseenContent {
            hasUnseenContent = false
        }
        if hadUserInteraction {
            hadUserInteraction = false
        }
    }

    private static func isUserDrivenPhase(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .tracking || phase == .decelerating
    }

    private var hasPendingGeometryOnlyMovement: Bool {
        pendingGeometryOnlyOlderMovement > 0
    }

    private func applyGeometryOnlyMovement(
        _ movement: GeometryOnlyMovement,
        isNearBottom: Bool
    ) -> Bool {
        guard !isPrependingHistory else {
            resetPendingGeometryOnlyMovement()
            return false
        }

        switch movement {
        case .towardOlderContent(let distance, let threshold):
            guard distance.isFinite, threshold.isFinite, distance > 0, threshold > 0 else {
                resetPendingGeometryOnlyMovement()
                return false
            }
            pendingGeometryOnlyOlderMovement += distance
            geometryOnlyAutoscrollVetoArmed = true
            return !isNearBottom && pendingGeometryOnlyOlderMovement >= threshold
        case .stationaryContentGrowth, .preserve:
            return false
        case .reset:
            resetPendingGeometryOnlyMovement()
            return false
        }
    }

    private func commitPendingGeometryOnlyContent() {
        if pendingGeometryOnlyHasUnseenContent {
            hasUnseenContent = true
        }
        resetPendingGeometryOnlyMovement()
    }

    private func resetPendingGeometryOnlyMovement() {
        if pendingGeometryOnlyOlderMovement != 0 {
            pendingGeometryOnlyOlderMovement = 0
        }
        if geometryOnlyAutoscrollVetoArmed {
            geometryOnlyAutoscrollVetoArmed = false
        }
        if pendingGeometryOnlyHasUnseenContent {
            pendingGeometryOnlyHasUnseenContent = false
        }
    }

    private struct TargetNavigationSnapshot {
        let userScrolledAway: Bool
        let hasUnseenContent: Bool
        let hadUserInteraction: Bool
        let isPrependingHistory: Bool
    }
}
