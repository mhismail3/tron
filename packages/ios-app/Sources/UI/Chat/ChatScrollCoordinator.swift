import SwiftUI
import TronMobileCore

struct ChatSemanticAnchor: Equatable, Sendable {
    let semanticID: String
    let renderedID: String
    let layoutEpoch: Int
    let viewportOffsetY: CGFloat
}

struct ChatInstalledLayoutEpoch: Equatable, Sendable {
    let value: Int
    let firstValidSampleRevision: Int
}

struct ChatPrependPage: Equatable, Sendable {
    let renderedAnchorID: String
    let installedLayout: ChatInstalledLayoutEpoch
}

enum ChatHistoryPageLoadResult: Equatable, Sendable {
    /// Canonical history installed. A page value means a semantic anchor can be
    /// restored; nil means the authoritative page installed without geometry.
    case installed(ChatPrependPage?)
    case failed
}

/// Owns explicit viewport intent, catch-up, semantic restore, and prepend
/// commands. Opening readiness is presentation-owned. Native anchoring owns
/// payload and size changes, while explicit semantic rows lease their exact
/// target through the installed layout transaction.
@Observable
@MainActor
final class ChatScrollCoordinator {
    nonisolated static let liveGrowthAnimationDuration = 0.16
    private struct SemanticFrameSample: Equatable {
        let layoutEpoch: Int
        let revision: Int
        let rawFrame: CGRect
        var frame: CGRect { rawFrame }
    }

    private enum CatchUpPhase: Equatable { case none, staged, final, settling }

    private struct LayoutRestore {
        let token: Int
        let anchor: ChatSemanticAnchor
        var renderedAnchorID: String?
        var expectedLayoutEpoch: Int?
        var requiredSampleRevision: Int
        var requiredGeometryRevision: Int
        var readyForMeasurement = false
        var correctionCount = 0
        var correctionCommandToken: Int?
        let directTarget: Bool
    }

    private struct PrependContext {
        let token: Int
        let anchor: ChatSemanticAnchor?
        var interrupted = false
        var renderedAnchorID: String?
        var expectedLayoutEpoch: Int?
        var readyForMeasurement = false
        var requiredSampleRevision: Int
        var requiredGeometryRevision: Int
        var correctionCount = 0
        var correctionCommandToken: Int?
        let completion: @MainActor (PerformanceResult) -> Void
    }

    private(set) var viewportMode: ChatViewportMode = .pinned
    private(set) var isAtBottom = true
    var userScrolledAway: Bool { viewportMode == .anchored }
    private(set) var hasUnreadContent = false
    private(set) var isUserInteracting = false
    var isPrependingHistory: Bool { prepend != nil }
    var canRequestHistoryPage: Bool {
        let hasCompatiblePendingCommand = command == nil || command?.origin == .layout
        return prepend == nil
            && catchUpPhase == .none
            && !visibleOpeningRevealPending
            && hasCompatiblePendingCommand && appliedTargetCommandToken == nil
            && targetReleaseToken == nil
    }
    private(set) var command: ChatScrollCommand?
    private(set) var commandRevision = 0
    private(set) var layoutEpoch = 0
    private(set) var tailSettlementGeneration = 0
    private(set) var pinnedPositionRevision = 0
    private(set) var maximumPrependSemanticExcursion: CGFloat = 0

    private let frameScheduler: DisplayFrameScheduler
    /// The transcript's origin-anchored layout. Geometry reaches this
    /// coordinator already adapted by the orientation owner, so every decision
    /// below reads one model — `distanceFromBottom` is the distance from the
    /// newest row, which is the exact content origin.
    private let orientation: ChatTranscriptOrientation
    private let clock: MonotonicClock
    private var presentation = 0
    private var viewportActivation = 0
    private var sequence = 0
    // Per-frame layout evidence. Geometry and row-frame callbacks read and
    // write these while SwiftUI lays out the transcript, and no view body
    // reads them. Observing them only let UIKit's layout observation tracking
    // count every callback as a layout invalidation of the hosting view, which
    // it reports as a feedback loop once enough rows publish in one pass.
    @ObservationIgnored private var geometry = ChatTranscriptGeometry.zero
    @ObservationIgnored private var geometryRevision = 0
    private var installedPhysicalRowSpine: ChatPhysicalRowSpineIdentity?
    /// Physical collection positions are diagnostic context only. They are
    /// supplied by the same row adapter that renders the installed spine so a
    /// target's relation to the terminal never relies on opaque identity tokens.
    private var installedPhysicalRowPositions: [String: Int] = [:]
    private var installedPhysicalTerminalPosition: Int?
    @ObservationIgnored private var rawSemanticFrames: [String: SemanticFrameSample] = [:]
    @ObservationIgnored private var semanticFrameRevision = 0
    /// Keeps opening presentation work gated through its validated first-ready
    /// frame, independently of cosmetic animation completion.
    private var visibleOpeningRevealPending = false
    private var appliedTargetCommandToken: Int?
    private var appliedTargetOrigin: ChatScrollCommand.Origin?
    private var targetReleaseToken: Int?
    private(set) var targetReleaseGeneration = 0
    private var catchUpPhase: CatchUpPhase = .none
    private var catchUpCommandToken: Int?
    private var catchUpUnreadBeforeJump = false
    private var layoutRestore: LayoutRestore?
    private var prepend: PrependContext?
    @ObservationIgnored private(set) var physicalTailEvidence: ChatPhysicalTailEvidence?
    @ObservationIgnored private var physicalTailEvidenceOffsetY: CGFloat?
    @ObservationIgnored private var physicalTailEvidenceContentHeight: CGFloat?
    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    @ObservationIgnored private var layoutRestoreTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var prependTask: Task<Void, Never>?
    @ObservationIgnored private var prependTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var targetReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var directPositionOwnership = false
    @ObservationIgnored private var viewportObservationActive = true
    @ObservationIgnored private var lastForegroundActivation: Int?
    @ObservationIgnored private var interactionTrace: ChatInteractionTrace?
    @ObservationIgnored private var interactionTraceContext: Int?

    init(
        frameScheduler: DisplayFrameScheduler = .displayLink,
        orientation: ChatTranscriptOrientation = .newestAtOrigin,
        clock: MonotonicClock = .continuous
    ) {
        self.frameScheduler = frameScheduler
        self.orientation = orientation
        self.clock = clock
    }

    func configureInteractionTrace(_ trace: ChatInteractionTrace, context: Int) {
        interactionTrace = trace
        interactionTraceContext = context
    }

    /// Diagnostic only: distinguish actual compact completion from the shared
    /// structural barrier's state when investigating premature target release.
    func recordEntranceDiagnostic(
        _ stage: ChatInteractionTrace.EntranceStage,
        renderedID: String,
        observedLayoutEpoch: Int
    ) {
        guard let interactionTrace, let context = interactionTraceContext else { return }
        var state = traceState()
        state.semanticRowToken = interactionTrace.identityToken(renderedID)
        state.observedLayoutEpoch = observedLayoutEpoch
        interactionTrace.entrance(stage, context: context, state: state)
    }

    var shouldShowCatchUpButton: Bool { viewportMode == .anchored }
    /// Canonical session authority continues advancing while a detached reader
    /// keeps one immutable render commit. Catch-up retains that freeze until its
    /// explicit tail command settles, then admits one newest projection.
    var defersAutomaticLiveProjectionIntake: Bool {
        viewportMode.defersAutomaticProjectionIntake(catchingUp: catchUpPhase != .none)
    }
    var blocksAutomaticLiveProjectionIntake: Bool {
        defersAutomaticLiveProjectionIntake
            || visibleOpeningRevealPending
    }
    var latestGeometry: ChatTranscriptGeometry { geometry }
    /// Native size-change anchoring is intent-based, not overflow-dependent.
    var usesPinnedSizeChangeAnchor: Bool { viewportMode == .pinned }
    var shouldTrackUnreadResponse: Bool { viewportMode == .anchored || catchUpPhase != .none }
    var isWaitingForPrependSemanticFrame: Bool {
        prepend?.readyForMeasurement == true && prepend?.correctionCommandToken == nil
    }
    var canAutomaticallyFollow: Bool {
        viewportMode == .pinned && !isUserInteracting && prepend == nil
            && catchUpPhase == .none
            && !visibleOpeningRevealPending
    }
    var canInstallPersistentBottomPosition: Bool {
        canAutomaticallyFollow && command == nil
            && appliedTargetCommandToken == nil && targetReleaseToken == nil
    }
    var admitsSubmission: Bool {
        prepend == nil
            && catchUpPhase == .none
            && !visibleOpeningRevealPending
    }
    /// Async transcript descendants may begin intrinsic-size work only after
    /// the presentation-owned opening reveal completes.
    var permitsAsynchronousTranscriptContent: Bool {
        !visibleOpeningRevealPending
    }

    var hasAppliedTargetLease: Bool { appliedTargetCommandToken != nil }
    var hasPendingTargetRelease: Bool { targetReleaseToken != nil }

    func resetForPresentation(
        _ presentation: Int? = nil,
        retainingVisibleViewport: Bool = false
    ) {
        cancelAllOwnedWork(result: .discarded)
        physicalTailEvidence = nil
        physicalTailEvidenceOffsetY = nil
        physicalTailEvidenceContentHeight = nil
        installedPhysicalRowSpine = nil
        installedPhysicalRowPositions = [:]
        installedPhysicalTerminalPosition = nil
        self.presentation = presentation ?? (self.presentation &+ 1)
        visibleOpeningRevealPending = !retainingVisibleViewport
        lastForegroundActivation = nil
        reduceViewport(.presentationReset(retainingViewport: retainingVisibleViewport))
        clearCommand()
        if viewportMode == .pinned { pinnedPositionRevision &+= 1 }
        // Semantic evidence is scoped to the current presentation epoch.
        advanceLayoutEpoch()
        guard !retainingVisibleViewport else { return }
        isAtBottom = true
        hasUnreadContent = false
        isUserInteracting = false
        directPositionOwnership = false
        geometry = .zero
        geometryRevision = 0
    }

    func beginInstalledLayoutEpoch() -> ChatInstalledLayoutEpoch {
        advanceLayoutEpoch()
        return ChatInstalledLayoutEpoch(
            value: layoutEpoch,
            firstValidSampleRevision: semanticFrameRevision
        )
    }

    private func semanticFrame(for renderedID: String) -> SemanticFrameSample? {
        guard let sample = rawSemanticFrames[renderedID] else { return nil }
        return SemanticFrameSample(
            layoutEpoch: sample.layoutEpoch,
            revision: sample.revision,
            rawFrame: orientation.transcriptFrame(
                sample.rawFrame,
                geometry: geometry
            )
        )
    }

    func semanticFrameChanged(renderedID: String, layoutEpoch: Int, frame: CGRect) {
        guard layoutEpoch == self.layoutEpoch else { return }
        // Rows and the tail marker report the scroll view's own frames. On the
        // origin-anchored path those measure upward from the visual bottom, so
        // every consumer below — the reader's anchor row, the marker's
        // placement against the viewport, a correction's signed residual — is
        // handed this single transcript-relative coordinate space.
        // SwiftUI can invoke an observation action again with the same frame
        // while the row tree settles. Such callbacks are inert unless an exact
        // active owner is awaiting later temporal evidence from that row.
        let previous = rawSemanticFrames[renderedID]
        let changed = previous?.layoutEpoch != layoutEpoch || previous?.rawFrame != frame
        let hasOwnedWaiter = layoutRestore != nil
            || prepend != nil

        // Ordinary duplicate callbacks are inert. An exact active owner may
        // still require the later native callback as temporal evidence after
        // its command/layout epoch, even when the frame value is unchanged.
        guard changed || hasOwnedWaiter else { return }
        semanticFrameRevision &+= 1
        rawSemanticFrames[renderedID] = SemanticFrameSample(
            layoutEpoch: layoutEpoch,
            revision: semanticFrameRevision,
            rawFrame: frame
        )
        // Existing samples update in O(1); bounded eviction scans only when a
        // new sample exceeds capacity.
        if renderedID == "transcript-bottom",
           let marker = semanticFrame(for: renderedID) {
            refreshPhysicalTailEvidence(marker: marker)
        }
        if rawSemanticFrames.count > 256,
           let oldest = rawSemanticFrames.min(by: { $0.value.revision < $1.value.revision })?.key {
            rawSemanticFrames[oldest] = nil
        }
        if let adaptedFrame = semanticFrame(for: renderedID)?.frame {
            recordPrependExcursionIfOwned(
                renderedID: renderedID, layoutEpoch: layoutEpoch, frame: adaptedFrame
            )
        }
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
    }

    func semanticAnchor(in timeline: ChatTranscriptTimeline) -> ChatSemanticAnchor? {
        let selected = timeline.ids.enumerated().compactMap { indexed
            -> (index: Int, renderedID: String, semanticID: String, frame: CGRect)? in
            let (index, renderedID) = indexed
            guard let semanticID = timeline.preferredSemanticIDByRenderedID[renderedID],
                  let sample = semanticFrame(for: renderedID),
                  sample.layoutEpoch == layoutEpoch,
                  sample.frame.maxY > 0,
                  sample.frame.minY < geometry.containerHeight else { return nil }
            return (index, renderedID, semanticID, sample.frame)
        }.min { lhs, rhs in
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            return lhs.index < rhs.index
        }
        guard let selected else { return nil }
        return ChatSemanticAnchor(
            semanticID: selected.semanticID,
            renderedID: selected.renderedID,
            layoutEpoch: layoutEpoch,
            viewportOffsetY: selected.frame.minY
        )
    }

    func scrollPositionChanged(isPositionedByUser: Bool) {
        directPositionOwnership = isPositionedByUser
        guard isPositionedByUser else { return }
        beginDirectInteraction()
    }

    func scrollPhaseChanged(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        finalGeometry: ChatTranscriptGeometry?
    ) {
        if let finalGeometry { admitGeometry(finalGeometry) }
        let wasDirect = Self.isDirectUserPhase(oldPhase) || isUserInteracting
        isUserInteracting = Self.isDirectUserPhase(newPhase)
        if isUserInteracting {
            beginDirectInteraction()
            return
        }
        guard newPhase == .idle else { return }
        if wasDirect, geometry.isAtCatchUpBoundary {
            pinAtTail()
        }
        directPositionOwnership = false
        // Releasing without moving away from the tail keeps pinned mode and
        // native size-change anchoring in control.
    }

    /// Tests and explicit opaque tree replacement use the unconditional epoch
    /// boundary. Mounted chat updates use the physical-spine overload below.
    func projectionInstalled() {
        advanceLayoutEpoch()
        geometryRevision &+= 1
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
    }

    func projectionInstalled(
        structure: ChatPhysicalRowSpineIdentity?,
        physicalRowPositions: [String: Int] = [:],
        physicalTerminalPosition: Int? = nil
    ) {
        installedPhysicalRowPositions = physicalRowPositions
        installedPhysicalTerminalPosition = physicalTerminalPosition
        guard let structure else {
            installedPhysicalRowSpine = nil
            projectionInstalled()
            traceProjection(.removed, structure: nil)
            return
        }
        guard structure != installedPhysicalRowSpine else {
            // Streaming text and shallow tool status changes keep the same
            // physical hosts. Their geometry callbacks update in place;
            // clearing every semantic frame on each token creates a costly
            // full-tree feedback loop and is not stale-tree protection.
            geometryRevision &+= 1
            evaluateLayoutRestoreIfReady()
            evaluatePrependIfReady()
            return
        }
        let change: ChatInteractionTrace.ProjectionChange = installedPhysicalRowSpine == nil
            ? .first
            : .changedSpine
        installedPhysicalRowSpine = structure
        advanceLayoutEpoch()
        traceProjection(change, structure: structure)
        geometryRevision &+= 1
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
    }

    func installedLayoutEpochChanged() {
        geometryRevision &+= 1
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
    }

    func geometryChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        admitGeometry(current, mayRepresentDirectViewportMovement: false)
    }

    /// Admits a sample whose visible viewport moved independently of content
    /// layout, including UIKit's status-bar scroll-to-top path.
    func viewportChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        admitGeometry(current, mayRepresentDirectViewportMovement: true)
    }

    private func admitGeometry(
        _ current: ChatTranscriptGeometry,
        mayRepresentDirectViewportMovement: Bool = true
    ) {
        // SwiftUI may deliver the same native geometry more than once in one
        // display frame while an observed anchor role settles. Re-publishing an
        // identical fact feeds that callback back into layout and can create an
        // OnScrollGeometryChange cycle without adding any evidence.
        if current == geometry {
            let hasOwnedWaiter = layoutRestore != nil
                || prepend != nil
                    || appliedTargetOrigin != nil
            // Identical callbacks are inert unless an exact active owner is
            // waiting for a later native sample after its command/layout epoch.
            guard hasOwnedWaiter else { return }
            geometryRevision &+= 1
            if let marker = semanticFrame(for: "transcript-bottom"), marker.layoutEpoch == layoutEpoch {
                refreshPhysicalTailEvidence(marker: marker)
            }
            evaluateLayoutRestoreIfReady()
            evaluatePrependIfReady()
                return
        }
        let previousGeometry = geometry
        // The status-bar tap uses UIKit's native scroll-to-top path and may
        // not publish `isPositionedByUser` or an interacting phase. Treat its
        // unmistakable retreat from the tail as direct ownership before a
        // layout update can re-apply the pinned bottom anchor.
        let hasAutomaticViewportTarget = command != nil || appliedTargetOrigin != nil
        if mayRepresentDirectViewportMovement,
           !hasAutomaticViewportTarget,
           viewportMode == .pinned,
           previousGeometry.isAtCatchUpBoundary,
           previousGeometry.hasScrollableOverflow,
           current.isValid,
           current.hasScrollableOverflow,
           !current.hasStructuralChange(from: previousGeometry),
           current.offsetY < previousGeometry.offsetY - 2,
           (current.visibleTopY ?? current.offsetY) <= 2,
           !current.isAtCatchUpBoundary {
            beginDirectInteraction(allowsBottomRubberBand: false)
        }
        geometry = current
        let viewportStructureChanged = abs(current.containerHeight - previousGeometry.containerHeight) > 0.5
            || abs(current.bottomInset - previousGeometry.bottomInset) > 0.5
        let contentHeightChangedMaterially = abs(current.contentHeight - previousGeometry.contentHeight)
            > max(80, current.containerHeight * 0.25)
        let meaningfulTraceChange = viewportStructureChanged
            || contentHeightChangedMaterially
            || current.isPastBottomEdge != previousGeometry.isPastBottomEdge
            || abs(current.distanceFromBottom - previousGeometry.distanceFromBottom)
                > max(80, current.containerHeight * 0.35)
        if let marker = semanticFrame(for: "transcript-bottom"), marker.layoutEpoch == layoutEpoch {
            refreshPhysicalTailEvidence(marker: marker)
        }
        geometryRevision &+= 1
        // Trace the evidence derived from this geometry, never the previous
        // marker classification paired with the new native dimensions.
        if meaningfulTraceChange {
            traceGeometry(.meaningfulChange)
        }
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
        if (isUserInteracting || directPositionOwnership),
           viewportMode == .pinned,
           current.isValid,
           current.hasScrollableOverflow,
           !current.hasStructuralChange(from: previousGeometry),
           current.offsetY < previousGeometry.offsetY - 2,
           !current.isAtCatchUpBoundary,
           !current.isPastBottomEdge {
            reduceViewport(.userTookOver)
            isAtBottom = false
        }
        let nextIsAtBottom = viewportMode == .pinned
            && (current.isAtBottom || current.isAtCatchUpBoundary)
        if isAtBottom != nextIsAtBottom { isAtBottom = nextIsAtBottom }
        if catchUpPhase == .settling, current.isAtCatchUpBoundary {
            finishCatchUpPinned()
        }
    }

    /// Releases an applied explicit target only after its owner has observed a
    /// display-frame boundary and consumed the exact current lease.
    func consumeTargetRelease() -> Bool {
        guard let token = targetReleaseToken,
              token == appliedTargetCommandToken,
              command == nil else { return false }
        targetReleaseToken = nil
        traceLease(.released, token: token, reason: .consumed)
        appliedTargetCommandToken = nil
        appliedTargetOrigin = nil
        return true
    }

    func completeVisibleOpeningReveal() {
        guard visibleOpeningRevealPending else { return }
        visibleOpeningRevealPending = false
    }

    func requestCatchUp(reduceMotion: Bool) {
        cancelLayoutRestore()
        cancelCatchUp(restoringAnchored: false)
        if prepend != nil { finishPrepend(result: .discarded) }
        catchUpUnreadBeforeJump = hasUnreadContent
        reduceViewport(.catchUpRequested)
        isAtBottom = false
        let threshold = max(320, geometry.containerHeight * 0.8)
        if !reduceMotion, geometry.distanceFromBottom > threshold {
            let reveal = min(140, max(80, geometry.containerHeight * 0.18))
            let bottomOffset = geometry.contentHeight + geometry.bottomInset - geometry.containerHeight
            catchUpPhase = .staged
            publish(.offsetY(max(0, bottomOffset - reveal)), animation: .disabled, origin: .catchUp)
        } else {
            catchUpPhase = .final
            publish(.tail, animation: reduceMotion ? .disabled : .smooth(duration: 0.30), origin: .catchUp)
        }
        catchUpCommandToken = command?.token
    }

    func transcriptProjectionWillChange(from installed: InstalledChatTranscript?) {
        guard prepend == nil, viewportMode == .anchored, layoutRestore == nil,
              let installed, let anchor = semanticAnchor(in: installed.timeline) else { return }
        sequence &+= 1
        let token = sequence
        let admittedPresentation = presentation
        layoutRestore = LayoutRestore(
            token: token,
            anchor: anchor,
            requiredSampleRevision: semanticFrameRevision,
            requiredGeometryRevision: geometryRevision,
            directTarget: false
        )
        layoutRestoreTimeoutTask?.cancel()
        layoutRestoreTimeoutTask = Task { [weak self, clock] in
            do { try await clock.sleep(.seconds(1)); try Task.checkCancellation() }
            catch { return }
            guard let self, self.presentation == admittedPresentation,
                  self.layoutRestore?.token == token else { return }
            self.cancelLayoutRestore()
        }
    }

    /// The system gesture is direct reader intent, not catch-up or a layout
    /// correction. Detach before applying an edge so incoming rows stay frozen.
    func requestOldestHistory(reduceMotion: Bool) {
        beginDirectInteraction(allowsBottomRubberBand: false)
        publish(.oldestHistory, animation: reduceMotion ? .disabled : .smooth(duration: 0.3), origin: .oldestHistory)
    }

    func requestHistoricalEntryScroll(semanticID: String, installed: InstalledChatTranscript?) {
        cancelLayoutRestore()
        sequence &+= 1
        let token = sequence
        let admittedPresentation = presentation
        layoutRestore = LayoutRestore(
            token: token,
            anchor: ChatSemanticAnchor(semanticID: semanticID, renderedID: "", layoutEpoch: layoutEpoch, viewportOffsetY: 0),
            requiredSampleRevision: semanticFrameRevision,
            requiredGeometryRevision: geometryRevision,
            directTarget: true
        )
        layoutRestoreTimeoutTask?.cancel()
        layoutRestoreTimeoutTask = Task { [weak self, clock] in
            do { try await clock.sleep(.seconds(1)); try Task.checkCancellation() } catch { return }
            guard let self, self.presentation == admittedPresentation, self.layoutRestore?.token == token else { return }
            self.cancelLayoutRestore()
        }
        installedTranscriptChanged(installed)
    }

    func installedTranscriptChanged(_ installed: InstalledChatTranscript?) {
        guard var restore = layoutRestore else { return }
        guard let installed else { return }
        guard (restore.directTarget || viewportMode == .anchored) else {
            cancelLayoutRestore()
            return
        }
        guard let renderedID = installed.timeline.renderedIDBySemanticID[restore.anchor.semanticID] else {
            if !restore.directTarget { cancelLayoutRestore() }
            return
        }
        let installedLayout = beginInstalledLayoutEpoch()
        restore.renderedAnchorID = renderedID
        restore.expectedLayoutEpoch = installedLayout.value
        restore.requiredSampleRevision = installedLayout.firstValidSampleRevision
        restore.requiredGeometryRevision = geometryRevision
        restore.readyForMeasurement = true
        layoutRestore = restore
        evaluateLayoutRestoreIfReady()
    }

    func submitted() {
        reduceViewport(.submitted)
        traceGeometry(.submissionBaseline)
    }

    /// Retires native callbacks captured by the previous viewport tree. A
    /// callback can arrive after uncovering with a stale `true` activity value,
    /// so activity booleans alone are not an admission fence.
    func viewportActivationChanged(_ activation: Int) {
        viewportActivation = activation
    }

    func admitsViewportCallback(capturedActivation: Int) -> Bool {
        viewportObservationActive && capturedActivation == viewportActivation
    }

    func viewportObservationChanged(isActive: Bool) {
        viewportObservationActive = isActive
    }

    /// Retains pinned ownership and retires targets captured by the old native tree.
    func foregroundViewportBecameActive(activation: Int? = nil) {
        viewportObservationActive = true
        guard viewportMode == .pinned, !isUserInteracting else { return }
        if let activation {
            guard lastForegroundActivation != activation else { return }
            lastForegroundActivation = activation
        }
        if catchUpPhase != .none {
            // Background suspension can interrupt before command application;
            // clear the whole catch-up owner so it cannot block later sends.
            cancelCatchUp(restoringAnchored: false)
        }
        // A ScrollPosition target is tied to the old native scroll tree. Retain
        // pinned intent, but retire that stale lease before the new tree emits
        // evidence; otherwise it can replay against a changed content hierarchy.
        // Detached readers never enter this branch.
        if command != nil || appliedTargetCommandToken != nil {
            clearCommand()
            retireAppliedTargetWithoutCallback()
            pinnedPositionRevision &+= 1
        }
        // Native geometry can remain numerically unchanged while the backing
        // UIScrollView is rebuilt. Rebase the semantic epoch so the next
        // marker callback measures the new tree instead of trusting stale data.
        advanceLayoutEpoch()
        geometryRevision &+= 1
    }

    func semanticResponseArrived() {
        if shouldTrackUnreadResponse { hasUnreadContent = true }
    }

    /// Owns the complete canonical history operation. Geometry is optional
    /// restoration evidence; a missing or stale anchor never turns an enabled
    /// history action into a no-op or creates a second untracked loading task.
    @discardableResult
    func beginHistoryPageLoad(
        anchor: ChatSemanticAnchor?,
        load: @escaping @MainActor @Sendable (ChatSemanticAnchor?) async -> ChatHistoryPageLoadResult,
        completion: @escaping @MainActor (PerformanceResult) -> Void
    ) -> Bool {
        guard canRequestHistoryPage else {
            completion(.discarded)
            return false
        }
        // Explicit history intent supersedes semantic restoration. Catch-up and
        // a visible opening reveal retain stronger ownership and are rejected above.
        cancelLayoutRestore()
        clearCommand()
        let admittedAnchor = anchor.flatMap(admittedPrependAnchor)
        sequence &+= 1
        let token = sequence
        let admittedPresentation = presentation
        reduceViewport(.prependBegan)
        prepend = PrependContext(
            token: token,
            anchor: admittedAnchor,
            requiredSampleRevision: semanticFrameRevision,
            requiredGeometryRevision: geometryRevision,
            completion: completion
        )
        maximumPrependSemanticExcursion = 0
        prependTimeoutTask = Task { [weak self, clock] in
            do { try await clock.sleep(.seconds(8)) } catch { return }
            guard let self, self.prepend?.token == token,
                  self.presentation == admittedPresentation else { return }
            self.prependTask?.cancel()
            self.finishPrepend(result: .failure)
        }
        prependTask = Task { [weak self] in
            let result = await load(admittedAnchor)
            guard let self, var context = self.prepend,
                  context.token == token,
                  self.presentation == admittedPresentation else { return }
            self.prependTask = nil
            guard !context.interrupted else {
                self.finishPrepend(result: .discarded)
                return
            }
            switch result {
            case .failed:
                self.finishPrepend(result: .failure)
            case .installed(nil):
                // Canonical data is already installed. With no admitted anchor
                // there is no app-generated offset command to settle.
                self.finishPrepend(result: .success)
            case .installed(let page?):
                guard let admittedAnchor,
                      page.installedLayout.value == self.layoutEpoch,
                      page.installedLayout.value != admittedAnchor.layoutEpoch else {
                    self.finishPrepend(result: .discarded)
                    return
                }
                context.renderedAnchorID = page.renderedAnchorID
                context.expectedLayoutEpoch = page.installedLayout.value
                context.requiredSampleRevision = page.installedLayout.firstValidSampleRevision
                context.readyForMeasurement = true
                self.prepend = context
                self.evaluatePrependIfReady()
            }
        }
        return true
    }

    private func admittedPrependAnchor(_ anchor: ChatSemanticAnchor) -> ChatSemanticAnchor? {
        guard anchor.layoutEpoch == layoutEpoch,
              let sample = semanticFrame(for: anchor.renderedID),
              sample.layoutEpoch == anchor.layoutEpoch,
              abs(sample.frame.minY - anchor.viewportOffsetY) <= 0.5,
              sample.frame.maxY > 0,
              sample.frame.minY < geometry.containerHeight else { return nil }
        return anchor
    }

    /// Applies exactly one currently-owned command. Its ScrollPosition target
    /// remains installed until its catch-up or semantic transaction observes
    /// settlement, then a token-owned release callback removes it before native
    /// size-change anchoring resumes.
    @discardableResult
    func commandApplied(_ applied: ChatScrollCommand) -> Bool {
        guard command?.token == applied.token, applied.presentation == presentation else {
            traceCommand(.rejected, command: applied)
            return false
        }
        command = nil
        commandRevision &+= 1
        targetReleaseToken = nil
        appliedTargetCommandToken = applied.token
        appliedTargetOrigin = applied.origin
        if applied.origin == .oldestHistory {
            // The status-bar jump to the oldest edge needs no marker proof: the
            // oldest end is legal as soon as the command lands. Release through
            // the bounded lease so native anchoring owns the viewport again from
            // the next frame and the load-earlier page request is admitted,
            // instead of holding an edge target across the jump.
            requestTargetRelease(applied.token)
        }
        if catchUpCommandToken == applied.token {
            catchUpCommandToken = nil
            if catchUpPhase == .staged {
                let admittedPresentation = presentation
                catchUpTask = Task { [weak self, frameScheduler] in
                    do { try await frameScheduler.nextFrame(); try Task.checkCancellation() }
                    catch {
                        guard let self, self.presentation == admittedPresentation else { return }
                        self.cancelCatchUp(restoringAnchored: true)
                        return
                    }
                    guard let self, self.presentation == admittedPresentation,
                          self.catchUpPhase == .staged, !self.isUserInteracting else { return }
                    self.catchUpTask = nil
                    self.catchUpPhase = .final
                    self.publish(.tail, animation: .smooth(duration: 0.30), origin: .catchUp)
                    self.catchUpCommandToken = self.command?.token
                }
            } else if catchUpPhase == .final {
                catchUpPhase = .settling
                // Native geometry can reach the tail before SwiftUI reports
                // command application. Re-evaluate that already-admitted fact
                // so catch-up cannot remain stuck and revoke draft actions.
                if !isUserInteracting, geometry.isAtCatchUpBoundary {
                    finishCatchUpPinned()
                }
            }
        }
        if var restore = layoutRestore, restore.correctionCommandToken == applied.token {
            restore.correctionCommandToken = nil
            restore.requiredSampleRevision = semanticFrameRevision
            restore.requiredGeometryRevision = geometryRevision
            restore.readyForMeasurement = true
            layoutRestore = restore
        }
        if var context = prepend, context.correctionCommandToken == applied.token {
            context.correctionCommandToken = nil
            context.requiredSampleRevision = semanticFrameRevision
            context.requiredGeometryRevision = geometryRevision
            context.readyForMeasurement = true
            prepend = context
        }
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
        traceCommand(.applied, command: applied)
        return true
    }

    func cancel() {
        cancelAllOwnedWork(result: .cancelled)
        clearCommand()
    }

    private func evaluateLayoutRestoreIfReady() {
        guard var restore = layoutRestore, restore.readyForMeasurement,
              command == nil, restore.correctionCommandToken == nil,
              (restore.directTarget || viewportMode == .anchored), !isUserInteracting,
              let renderedID = restore.renderedAnchorID,
              restore.expectedLayoutEpoch == layoutEpoch,
              geometryRevision > restore.requiredGeometryRevision else { return }
        if restore.directTarget {
            // An offscreen lazy row has no frame until it is materialized.
            // Its installed identity and current viewport layout admit the jump;
            // frame evidence is needed only for relative offset restoration.
            cancelLayoutRestore()
            publish(.row(renderedID), animation: .smooth(duration: 0.25), origin: .layout)
            return
        }
        guard let sample = semanticFrame(for: renderedID),
              sample.layoutEpoch == layoutEpoch,
              sample.revision > restore.requiredSampleRevision else { return }
        restore.readyForMeasurement = false
        let residual = sample.frame.minY - restore.anchor.viewportOffsetY
        if abs(residual) <= 1 || restore.correctionCount >= 2 {
            cancelLayoutRestore()
            return
        }
        restore.correctionCount &+= 1
        let requested = orientation.correctedOffsetY(
            currentModelOffsetY: geometry.offsetY,
            visualOffset: residual
        )
        publish(.offsetY(requested), animation: .disabled, origin: .layout)
        restore.correctionCommandToken = command?.token
        layoutRestore = restore
    }

    private func evaluatePrependIfReady() {
        guard var context = prepend, context.readyForMeasurement,
              command == nil, context.correctionCommandToken == nil, !context.interrupted,
              let anchor = context.anchor,
              let renderedID = context.renderedAnchorID,
              context.expectedLayoutEpoch == layoutEpoch,
              let sample = semanticFrame(for: renderedID), sample.layoutEpoch == layoutEpoch,
              sample.revision > context.requiredSampleRevision,
              geometryRevision > context.requiredGeometryRevision else { return }
        context.readyForMeasurement = false
        let residual = sample.frame.minY - anchor.viewportOffsetY
        maximumPrependSemanticExcursion = max(maximumPrependSemanticExcursion, abs(residual))
        if abs(residual) <= 1 {
            prepend = context
            finishPrepend(result: .success)
            return
        }
        guard context.correctionCount < 2 else {
            prepend = context
            finishPrepend(result: .failure)
            return
        }
        context.correctionCount &+= 1
        let requested = orientation.correctedOffsetY(
            currentModelOffsetY: geometry.offsetY,
            visualOffset: residual
        )
        publish(.offsetY(requested), animation: .disabled, origin: .prepend)
        context.correctionCommandToken = command?.token
        prepend = context
    }

    private func recordPrependExcursionIfOwned(renderedID: String, layoutEpoch: Int, frame: CGRect) {
        guard let context = prepend, let anchor = context.anchor,
              context.renderedAnchorID == renderedID,
              context.expectedLayoutEpoch == layoutEpoch else { return }
        maximumPrependSemanticExcursion = max(
            maximumPrependSemanticExcursion,
            abs(frame.minY - anchor.viewportOffsetY)
        )
    }

    private func pinAtTail() {
        let changed = viewportMode == .anchored || !isAtBottom
        reduceViewport(.userReturnedToTail)
        isAtBottom = true
        hasUnreadContent = false
        directPositionOwnership = false
        if changed { tailSettlementGeneration &+= 1 }
    }

    private func finishCatchUpPinned() {
        requestAppliedTargetRelease(origin: .catchUp)
        catchUpTask?.cancel()
        catchUpTask = nil
        catchUpPhase = .none
        catchUpCommandToken = nil
        catchUpUnreadBeforeJump = false
        pinAtTail()
    }

    private func cancelCatchUp(restoringAnchored: Bool) {
        catchUpTask?.cancel()
        catchUpTask = nil
        let token = catchUpCommandToken
        catchUpCommandToken = nil
        let wasActive = catchUpPhase != .none
        catchUpPhase = .none
        if let token, command?.token == token { clearCommand() }
        requestAppliedTargetRelease(origin: .catchUp)
        if restoringAnchored, wasActive {
            reduceViewport(.userTookOver)
            isAtBottom = false
            hasUnreadContent = catchUpUnreadBeforeJump || hasUnreadContent
        }
        catchUpUnreadBeforeJump = false
    }

    private func beginDirectInteraction(allowsBottomRubberBand: Bool = true) {
        retireAppliedTargetWithoutCallback()
        let isBottomRubberBand = allowsBottomRubberBand
            && viewportMode == .pinned
            && geometry.isValid
            && (geometry.isAtCatchUpBoundary || geometry.isPlausibleBottomRubberBand)
        if !isBottomRubberBand {
            reduceViewport(.userTookOver)
            isAtBottom = false
        }
        abandonAutomaticTransactionsForDirectInteraction()
    }

    private func abandonAutomaticTransactionsForDirectInteraction() {
        cancelLayoutRestore()
        cancelCatchUp(restoringAnchored: true)
        if var context = prepend {
            context.interrupted = true
            prepend = context
            prependTask?.cancel()
            finishPrepend(result: .discarded)
        }
        clearCommand()
    }

    private func cancelLayoutRestore() {
        layoutRestoreTimeoutTask?.cancel()
        layoutRestoreTimeoutTask = nil
        if let token = layoutRestore?.correctionCommandToken, command?.token == token {
            clearCommand()
        }
        requestAppliedTargetRelease(origin: .layout)
        layoutRestore = nil
    }

    private func finishPrepend(result: PerformanceResult) {
        guard let context = prepend else { return }
        prependTask = nil
        prependTimeoutTask?.cancel()
        prependTimeoutTask = nil
        if let token = context.correctionCommandToken, command?.token == token { clearCommand() }
        requestAppliedTargetRelease(origin: .prepend)
        prepend = nil
        reduceViewport(.prependEnded)
        context.completion(result)
    }

    private func cancelAllOwnedWork(result: PerformanceResult) {
        visibleOpeningRevealPending = false
        retireAppliedTargetWithoutCallback()
        cancelLayoutRestore()
        cancelCatchUp(restoringAnchored: false)
        prependTask?.cancel()
        prependTimeoutTask?.cancel()
        let prependCompletion = prepend?.completion
        prepend = nil
        prependCompletion?(result)
        prependTask = nil
        prependTimeoutTask = nil
    }

    private func requestTargetRelease(_ token: Int?) {
        guard let token,
              command == nil,
              appliedTargetCommandToken == token,
              targetReleaseToken != token else { return }
        targetReleaseTask?.cancel()
        targetReleaseToken = token
        traceLease(.releaseRequested, token: token, reason: .settledEvidence)
        let admittedPresentation = presentation
        targetReleaseTask = Task { [weak self, frameScheduler] in
            do { try await frameScheduler.nextFrame(); try Task.checkCancellation() }
            catch { return }
            guard let self,
                  self.presentation == admittedPresentation,
                  self.command == nil,
                  self.appliedTargetCommandToken == token,
                  self.targetReleaseToken == token else { return }
            self.targetReleaseTask = nil
            self.traceLease(.releaseReady, token: token, reason: .frameBoundary)
            self.targetReleaseGeneration &+= 1
        }
    }

    private func requestAppliedTargetRelease(origin: ChatScrollCommand.Origin) {
        guard appliedTargetOrigin == origin else { return }
        requestTargetRelease(appliedTargetCommandToken)
    }

    private func retireAppliedTargetWithoutCallback() {
        targetReleaseTask?.cancel()
        targetReleaseTask = nil
        targetReleaseToken = nil
        appliedTargetCommandToken = nil
        appliedTargetOrigin = nil
    }

    private func reduceViewport(_ intent: ChatViewportIntent) {
        let previous = viewportMode
        viewportMode.reduce(intent)
        // Direct native phase callbacks can repeat without changing ownership.
        // Preserve meaningful lifecycle intents while suppressing duplicate
        // reader/tail transitions from the diagnostic hot path.
        if previous == viewportMode,
           intent == .userTookOver || intent == .userReturnedToTail {
            return
        }
        guard let interactionTrace, let interactionTraceContext else { return }
        interactionTrace.viewportTransition(
            context: interactionTraceContext,
            from: previous,
            to: viewportMode,
            intent: intent,
            state: traceState()
        )
    }

    private func traceProjection(
        _ change: ChatInteractionTrace.ProjectionChange,
        structure: ChatPhysicalRowSpineIdentity?
    ) {
        guard let interactionTrace, let interactionTraceContext else { return }
        interactionTrace.projection(
            change,
            context: interactionTraceContext,
            state: traceState(structure: structure)
        )
    }

    private func traceGeometry(_ reason: ChatInteractionTrace.GeometryReason) {
        guard let interactionTrace, let interactionTraceContext else { return }
        interactionTrace.geometry(reason, context: interactionTraceContext, state: traceState())
    }

    private func traceTailEdge(
        _ stage: ChatInteractionTrace.TailEdgeStage,
        previous: ChatPhysicalTailEvidence,
        previousOffsetY: CGFloat?,
        previousContentHeight: CGFloat?
    ) {
        guard canAutomaticallyFollow, !directPositionOwnership,
              let interactionTrace, let interactionTraceContext else { return }
        interactionTrace.tailEdge(
            stage,
            context: interactionTraceContext,
            state: traceState(),
            previousClassification: previous.classification,
            previousTailDisplacement: previous.signedDisplacement,
            previousOffsetY: previousOffsetY,
            previousContentHeight: previousContentHeight
        )
    }

    private func traceLease(
        _ stage: ChatInteractionTrace.LeaseStage,
        token: Int?,
        reason: ChatInteractionTrace.LeaseReason
    ) {
        guard let interactionTrace, let interactionTraceContext else { return }
        interactionTrace.lease(
            stage,
            context: interactionTraceContext,
            token: token,
            reason: reason,
            state: traceState()
        )
    }

    private func traceCommand(
        _ stage: ChatInteractionTrace.CommandStage,
        command: ChatScrollCommand
    ) {
        guard let interactionTrace, let interactionTraceContext else { return }
        interactionTrace.command(
            stage,
            context: interactionTraceContext,
            command: command,
            state: traceState()
        )
    }

    private var requestedRowOffsetFromTerminal: Int? {
        let requestedPhysicalID = command.flatMap { command in
                switch command.destination {
                case .row(let id): id
                case .tail, .offsetY, .oldestHistory: nil
                }
            }
        guard let requestedPhysicalID,
              let requestedPosition = installedPhysicalRowPositions[requestedPhysicalID],
              let terminalPosition = installedPhysicalTerminalPosition else { return nil }
        return requestedPosition - terminalPosition
    }

    private func traceState(
        structure: ChatPhysicalRowSpineIdentity? = nil
    ) -> ChatInteractionTrace.State {
        ChatInteractionTrace.State(
            presentationEpoch: presentation,
            layoutEpoch: layoutEpoch,
            canonicalRows: structure?.timelineIDs.count,
            runtimeRows: structure?.runtimeIDs.count,
            queueRows: structure?.queueIDs.count,
            hasLifecycleRow: structure.map { $0.lifecycleID != nil },
            viewportMode: viewportMode,
            isUserInteracting: isUserInteracting,
            isPositionedByUser: directPositionOwnership,
            distanceFromBottom: geometry.isValid ? geometry.distanceFromBottom : nil,
            offsetY: geometry.isValid ? geometry.offsetY : nil,
            contentHeight: geometry.isValid ? geometry.contentHeight : nil,
            containerHeight: geometry.isValid ? geometry.containerHeight : nil,
            bottomInset: geometry.isValid ? geometry.bottomInset : nil,
            isPastBottomEdge: geometry.isValid ? geometry.isPastBottomEdge : nil,
            tailClassification: physicalTailEvidence?.classification,
            tailDisplacement: physicalTailEvidence?.signedDisplacement,
            hasCommand: command != nil,
            hasAppliedTarget: appliedTargetCommandToken != nil,
            hasPendingRelease: targetReleaseToken != nil,
            geometryRevision: geometryRevision,
            semanticRevision: semanticFrameRevision,
            markerRevision: physicalTailEvidence?.semanticFrameRevision,
            requestedRowOffsetFromTerminal: requestedRowOffsetFromTerminal,
            nativeTailEvidence: physicalTailEvidence.map {
                $0.presentationEpoch == presentation && $0.layoutEpoch == layoutEpoch
            }
        )
    }

    private func publish(
        _ destination: ChatScrollCommand.Destination,
        animation: ChatScrollAnimation,
        origin: ChatScrollCommand.Origin
    ) {
        guard command == nil else { return }
        targetReleaseTask?.cancel()
        targetReleaseTask = nil
        targetReleaseToken = nil
        sequence &+= 1
        command = ChatScrollCommand(
            token: sequence,
            presentation: presentation,
            origin: origin,
            destination: destination,
            animation: animation
        )
        commandRevision &+= 1
        traceCommand(.issued, command: command!)
    }

    private func clearCommand() {
        guard let command else { return }
        traceCommand(.cleared, command: command)
        self.command = nil
        commandRevision &+= 1
    }

    private func advanceLayoutEpoch() {
        layoutEpoch &+= 1
        physicalTailEvidence = nil
        physicalTailEvidenceOffsetY = nil
        physicalTailEvidenceContentHeight = nil
        rawSemanticFrames.removeAll(keepingCapacity: true)
    }

    private func refreshPhysicalTailEvidence(marker: SemanticFrameSample) {
        let previousEvidence = physicalTailEvidence
        // Native underflow alignment retains a content-local edge. The marker
        // and this edge share scroll-view coordinates; subtracting the composer
        // inset again would misclassify correctly visible short content.
        let visibleHeight = min(geometry.contentHeight, geometry.containerHeight)
        let visibleBounds = visibleHeight > 0 && visibleHeight.isFinite
            ? CGRect(x: 0, y: 0, width: 1, height: visibleHeight)
            : nil
        let evidence = ChatPhysicalTailEvidence.make(
            presentationEpoch: presentation,
            layoutEpoch: layoutEpoch,
            semanticFrameRevision: marker.revision,
            markerFrame: marker.frame,
            visibleBounds: visibleBounds
        )
        let previousOffsetY = physicalTailEvidenceOffsetY
        let previousContentHeight = physicalTailEvidenceContentHeight
        // Keep the latest SwiftUI viewport sample even when the marker's
        // classification and frame are unchanged. A later classification edge
        // must describe the immediately preceding geometry, not an older
        // marker callback.
        if evidence == physicalTailEvidence {
            physicalTailEvidenceOffsetY = geometry.isValid ? geometry.offsetY : nil
            physicalTailEvidenceContentHeight = geometry.isValid ? geometry.contentHeight : nil
            return
        }
        physicalTailEvidence = evidence
        physicalTailEvidenceOffsetY = geometry.isValid ? geometry.offsetY : nil
        physicalTailEvidenceContentHeight = geometry.isValid ? geometry.contentHeight : nil
        if let previousEvidence,
           previousEvidence.presentationEpoch == presentation,
           previousEvidence.layoutEpoch == layoutEpoch {
            let wasDisplaced = previousEvidence.classification == .aboveViewport
                || previousEvidence.classification == .belowViewport
            let isDisplaced = evidence.classification == .aboveViewport
                || evidence.classification == .belowViewport
            if previousEvidence.classification == .aligned && isDisplaced {
                traceTailEdge(.firstDisplacement, previous: previousEvidence,
                              previousOffsetY: previousOffsetY,
                              previousContentHeight: previousContentHeight)
            } else if wasDisplaced && evidence.classification == .aligned {
                traceTailEdge(.recovered, previous: previousEvidence,
                              previousOffsetY: previousOffsetY,
                              previousContentHeight: previousContentHeight)
            }
        }

    }

    private static func isDirectUserPhase(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .tracking || phase == .decelerating
    }
}
