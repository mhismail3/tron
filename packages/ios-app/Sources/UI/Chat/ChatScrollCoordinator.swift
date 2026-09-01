import SwiftUI

enum ChatScrollAnimation: Equatable, Sendable {
    case disabled
    case smooth(duration: Double)
}

struct ChatScrollCommand: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case presentation
        case catchUp
        case layout
        case prepend
        case tailMaterialization
        case physicalTailRepair
    }

    enum Destination: Equatable, Sendable {
        case tail
        case openingTail(String)
        case offsetY(CGFloat)
    }

    let token: Int
    let presentation: Int
    let origin: Origin
    let destination: Destination
    let animation: ChatScrollAnimation
}

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

/// Owns explicit viewport intent plus opening, catch-up, semantic restore, and
/// prepend commands. Native anchoring owns payload and size changes. A genuinely
/// New lazy rows lease the stable tail sentinel through their exact layout
/// transaction. Foreground resume retains native ownership; signed-marker drift
/// admits bounded repair.
@Observable
@MainActor
final class ChatScrollCoordinator {
    static let defaultOpeningTailTimeout: Duration = .milliseconds(750)
    static let liveGrowthAnimationDuration = 0.16

    private struct SemanticFrameSample: Equatable {
        let layoutEpoch: Int
        let revision: Int
        let frame: CGRect
    }

    private struct TailMaterialization {
        var renderedID: String?
        var requiredRevision: Int?
        var requiredLayoutEpoch: Int?
        let layoutOwnerRenderedID: String?
        let layoutTransactionID: Int?
        var layoutSettled: Bool
    }

    private struct PendingTailMaterialization {
        let renderedID: String
        let layoutOwnerRenderedID: String?
        let layoutTransactionID: Int?
        var layoutSettled: Bool
    }

    private struct OpeningTailFinalWaiter {
        let id: Int
        let token: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct OpeningTailContext: Equatable {
        var token: Int
        var targetRenderedID: String
        var targetSample: SemanticFrameSample?
        var presentation: Int
        var commandToken: Int?
        var commandSemanticRevision: Int?
        var commandGeometryRevision: Int?
        var commandAttemptCount: Int
        var positionedBestEffort: Bool
    }

    private struct OpeningTailPostRevealContext: Equatable {
        var base: OpeningTailContext
        var stableFrameCount = 0
        var stableSemanticRevision: Int?
        var stableGeometryRevision: Int?
    }

    private enum OpeningTailPhase: Equatable {
        case idle
        case positioning(OpeningTailContext)
        case positioned(OpeningTailContext)
        case postReveal(OpeningTailPostRevealContext)

        var isActive: Bool {
            if case .idle = self { return false }
            return true
        }

        var context: OpeningTailContext? {
            switch self {
            case .idle: nil
            case .positioning(let value), .positioned(let value): value
            case .postReveal(let value): value.base
            }
        }
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
        prepend == nil && catchUpPhase == .none && !openingTailSettlementPending
    }
    private(set) var command: ChatScrollCommand?
    private(set) var commandRevision = 0
    private(set) var layoutEpoch = 0
    private(set) var tailSettlementGeneration = 0
    private(set) var pinnedPositionRevision = 0
    private(set) var maximumPrependSemanticExcursion: CGFloat = 0

    private let frameScheduler: DisplayFrameScheduler
    private let clock: MonotonicClock
    private let openingTailTimeout: Duration
    private var presentation = 0
    private var sequence = 0
    private var geometry = ChatTranscriptGeometry.zero
    private var geometryRevision = 0
    private var retainedViewportReconciliationPending = false
    private var semanticFrames: [String: SemanticFrameSample] = [:]
    private var semanticFrameRevision = 0
    private var openingTailPhase: OpeningTailPhase = .idle
    private var openingTailContinuation: CheckedContinuation<Bool, Never>?
    private var openingTailFinalWaiters: [OpeningTailFinalWaiter] = []
    private var nextOpeningTailFinalWaiterID = 0
    private var openingTailFrameTaskGeneration = 0
    private var appliedTargetCommandToken: Int?
    private var appliedTargetOrigin: ChatScrollCommand.Origin?
    private var tailMaterialization: TailMaterialization?
    private var tailMaterializationEvidenceRevision = 0
    private var targetReleaseEvidenceRevision: Int?
    private var pendingTailMaterialization: PendingTailMaterialization?
    /// Entrance completion may arrive synchronously before ChatView admits the
    /// exact local lifecycle row. Retain only its unique physical ID until that
    /// admission arrives; presentation reset clears this bounded ledger.
    private var preAdmissionSettledEntranceIDs: [String] = []
    private var targetReleaseToken: Int?
    private(set) var targetReleaseGeneration = 0
    private var catchUpPhase: CatchUpPhase = .none
    private var catchUpCommandToken: Int?
    private var catchUpUnreadBeforeJump = false
    private var layoutRestore: LayoutRestore?
    private var prepend: PrependContext?
    private(set) var physicalTailEvidence: ChatPhysicalTailEvidence?
    private var physicalTailRepairAttempts = 0
    private var physicalTailRepairEvidenceRevision: Int?
    private var physicalTailRepairCommandToken: Int?
    private var physicalTailRepairIssuedEvidenceRevision: Int?
    private var physicalTailRepairFailedDisplacement: CGFloat?
    /// Reveal/layout transitions must publish a new marker frame before drift
    /// repair can inspect it; the lifted opening frame is not repair evidence.
    private var physicalTailRepairBlockedUntilEvidenceRevision: Int?

    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    @ObservationIgnored private var layoutRestoreTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var prependTask: Task<Void, Never>?
    @ObservationIgnored private var prependTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var openingTailFrameTask: Task<Void, Never>?
    @ObservationIgnored private var openingTailTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var physicalTailRepairTask: Task<Void, Never>?
    @ObservationIgnored private var targetReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var tailMaterializationSettlementTask: Task<Void, Never>?
    @ObservationIgnored private var directPositionOwnership = false

    #if HOSTED_TEST
    private struct HostedCommandWaiter {
        let id: Int
        let continuation: CheckedContinuation<ChatScrollCommand, Error>
    }
    private struct HostedPrependSampleWaiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    @ObservationIgnored private var hostedCommandWaiters: [HostedCommandWaiter] = []
    @ObservationIgnored private var hostedPrependSampleWaiters: [HostedPrependSampleWaiter] = []
    private var nextHostedCommandWaiterID = 0
    private var nextHostedPrependSampleWaiterID = 0
    #endif

    init(
        frameScheduler: DisplayFrameScheduler = .displayLink,
        clock: MonotonicClock = .continuous,
        openingTailTimeout: Duration = ChatScrollCoordinator.defaultOpeningTailTimeout
    ) {
        self.frameScheduler = frameScheduler
        self.clock = clock
        self.openingTailTimeout = openingTailTimeout
    }

    var shouldShowCatchUpButton: Bool { viewportMode == .anchored }
    var latestGeometry: ChatTranscriptGeometry { geometry }
    /// Native size-change anchoring is intent-based, not overflow-dependent.
    /// The bounded physical repair is the only explicit fallback.
    var usesPinnedSizeChangeAnchor: Bool { viewportMode == .pinned }
    var shouldTrackUnreadResponse: Bool { viewportMode == .anchored || catchUpPhase != .none }
    var isWaitingForPrependSemanticFrame: Bool {
        prepend?.readyForMeasurement == true && prepend?.correctionCommandToken == nil
    }
    var canAutomaticallyFollow: Bool {
        viewportMode == .pinned && !isUserInteracting && prepend == nil
            && catchUpPhase == .none && !openingTailPhase.isActive
    }
    var canInstallPersistentBottomPosition: Bool {
        canAutomaticallyFollow && command == nil
            && appliedTargetCommandToken == nil && targetReleaseToken == nil
    }
    var admitsSubmission: Bool {
        prepend == nil && catchUpPhase == .none && !openingTailPhase.isActive
    }

    private var openingTailSettlementPending: Bool { openingTailPhase.isActive }
    private var openingTailToken: Int? { openingTailPhase.context?.token }
    private var openingTailPresentation: Int? { openingTailPhase.context?.presentation }

    func resetForPresentation(
        _ presentation: Int? = nil,
        retainingVisibleViewport: Bool = false
    ) {
        cancelAllOwnedWork(result: .discarded)
        physicalTailEvidence = nil
        physicalTailRepairEvidenceRevision = nil
        physicalTailRepairCommandToken = nil
        physicalTailRepairIssuedEvidenceRevision = nil
        physicalTailRepairFailedDisplacement = nil
        physicalTailRepairBlockedUntilEvidenceRevision = nil
        physicalTailRepairAttempts = 0
        self.presentation = presentation ?? (self.presentation &+ 1)
        viewportMode.reduce(.presentationReset(retainingViewport: retainingVisibleViewport))
        retainedViewportReconciliationPending = retainingVisibleViewport
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

    func semanticFrameChanged(renderedID: String, layoutEpoch: Int, frame: CGRect) {
        guard layoutEpoch == self.layoutEpoch else { return }
        semanticFrameRevision &+= 1
        semanticFrames[renderedID] = SemanticFrameSample(
            layoutEpoch: layoutEpoch,
            revision: semanticFrameRevision,
            frame: frame
        )
        // Existing samples update in O(1); bounded eviction scans only when a
        // new sample exceeds capacity.
        if renderedID == "transcript-bottom" {
            refreshPhysicalTailEvidence(markerFrame: frame)
            reconcileRetainedViewport(with: geometry)
        }
        if appliedTargetOrigin == .tailMaterialization,
           (tailMaterialization?.renderedID == renderedID || renderedID == "transcript-bottom") {
            tailMaterializationEvidenceChanged()
        }
        if semanticFrames.count > 256,
           let oldest = semanticFrames.min(by: { $0.value.revision < $1.value.revision })?.key {
            semanticFrames[oldest] = nil
        }
        recordPrependExcursionIfOwned(renderedID: renderedID, layoutEpoch: layoutEpoch, frame: frame)
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
        if openingTailPhase.context?.targetRenderedID == renderedID {
            updateOpeningTargetSample(semanticFrames[renderedID])
            evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        }
    }

    func semanticAnchor(in timeline: ChatTranscriptTimeline) -> ChatSemanticAnchor? {
        let candidates = timeline.ids.compactMap { renderedID -> (String, String, CGRect)? in
            guard let semanticID = timeline.preferredSemanticIDByRenderedID[renderedID],
                  let sample = semanticFrames[renderedID],
                  sample.layoutEpoch == layoutEpoch,
                  sample.frame.maxY > 0,
                  sample.frame.minY < geometry.containerHeight else { return nil }
            return (renderedID, semanticID, sample.frame)
        }
        guard let selected = candidates.min(by: { lhs, rhs in
            if lhs.2.minY != rhs.2.minY { return lhs.2.minY < rhs.2.minY }
            return (timeline.ids.firstIndex(of: lhs.0) ?? 0)
                < (timeline.ids.firstIndex(of: rhs.0) ?? 0)
        }) else { return nil }
        return ChatSemanticAnchor(
            semanticID: selected.1,
            renderedID: selected.0,
            layoutEpoch: layoutEpoch,
            viewportOffsetY: selected.2.minY
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
    }

    /// A mounted projection can change row heights without changing canonical
    /// identity (for example lifecycle-only, tool, or compaction settlement).
    /// Rebase all semantic and physical evidence before delayed callbacks from
    /// the previous tree are allowed to settle a lease.
    func projectionInstalled() {
        advanceLayoutEpoch()
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
        admitGeometry(current)
    }

    func viewportChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        admitGeometry(current)
    }

    private func admitGeometry(_ current: ChatTranscriptGeometry) {
        // SwiftUI may deliver the same native geometry more than once in one
        // display frame while an observed anchor role settles. Re-publishing an
        // identical fact feeds that callback back into layout and can create an
        // OnScrollGeometryChange cycle without adding any evidence.
        if current == geometry {
            if let marker = semanticFrames["transcript-bottom"], marker.layoutEpoch == layoutEpoch {
                refreshPhysicalTailEvidence(markerFrame: marker.frame)
            }
            reconcileRetainedViewport(with: current)
            // Owned semantic restore/prepend transactions may require a fresh
            // sample revision even when the native values are unchanged. Do
            // not assign the observed geometry again.
            geometryRevision &+= 1
            evaluateLayoutRestoreIfReady()
            evaluatePrependIfReady()
            evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
            return
        }
        let previousGeometry = geometry
        // The status-bar tap uses UIKit's native scroll-to-top path and may
        // not publish `isPositionedByUser` or an interacting phase. Treat its
        // unmistakable retreat from the tail as direct ownership before a
        // layout update can re-apply the pinned bottom anchor.
        let hasAutomaticViewportTarget = command != nil || appliedTargetOrigin != nil
        if !openingTailSettlementPending,
           !hasAutomaticViewportTarget,
           viewportMode == .pinned,
           previousGeometry.isAtCatchUpBoundary,
           previousGeometry.hasScrollableOverflow,
           current.isValid,
           current.hasScrollableOverflow,
           !current.hasStructuralChange(from: previousGeometry),
           current.offsetY < previousGeometry.offsetY - 2,
           !current.isAtCatchUpBoundary {
            beginDirectInteraction(allowsBottomRubberBand: false)
        }
        geometry = current
        if appliedTargetOrigin == .tailMaterialization {
            tailMaterializationEvidenceChanged()
        }
        if let marker = semanticFrames["transcript-bottom"], marker.layoutEpoch == layoutEpoch {
            refreshPhysicalTailEvidence(markerFrame: marker.frame)
        }
        geometryRevision &+= 1
        reconcileRetainedViewport(with: current)
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
        evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        guard !openingTailSettlementPending else { return }
        if (isUserInteracting || directPositionOwnership),
           viewportMode == .pinned,
           current.isValid,
           current.hasScrollableOverflow,
           !current.hasStructuralChange(from: previousGeometry),
           current.offsetY < previousGeometry.offsetY - 2,
           !current.isAtCatchUpBoundary,
           !current.isPastBottomEdge {
            viewportMode.reduce(.userTookOver)
            isAtBottom = false
        }
        let nextIsAtBottom = viewportMode == .pinned
            && (current.isAtBottom || current.isAtCatchUpBoundary)
        if isAtBottom != nextIsAtBottom { isAtBottom = nextIsAtBottom }
        if catchUpPhase == .settling, current.isAtCatchUpBoundary {
            finishCatchUpPinned()
        }
    }

    private func reconcileRetainedViewport(with current: ChatTranscriptGeometry) {
        guard retainedViewportReconciliationPending, current.isValid else { return }
        if isUserInteracting || !current.isAtCatchUpBoundary {
            retainedViewportReconciliationPending = false
            return
        }
        let hasCurrentAlignedTail = physicalTailEvidence.map {
            $0.presentationEpoch == presentation
                && $0.layoutEpoch == layoutEpoch
                && $0.classification == .aligned
        } == true
        guard hasCurrentAlignedTail else { return }
        retainedViewportReconciliationPending = false
        pinAtTail()
    }

    func positionOpeningTail(targetRenderedID: String?) async -> Bool {
        guard let targetRenderedID else {
            viewportMode.reduce(.opened)
            return true
        }
        guard prepend == nil else { return false }
        clearOpeningTailSettlement(positioningSucceeded: false)
        sequence &+= 1
        let token = sequence
        let admittedPresentation = presentation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                beginOpeningTailSettlement(
                    token: token,
                    targetRenderedID: targetRenderedID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.clearOpeningTailSettlement(
                    ifToken: token,
                    ifPresentation: admittedPresentation,
                    positioningSucceeded: false
                )
            }
        }
    }

    func requestOpeningTail(targetRenderedID: String?) {
        guard prepend == nil else { return }
        clearOpeningTailSettlement(positioningSucceeded: false)
        guard let targetRenderedID else { return }
        sequence &+= 1
        beginOpeningTailSettlement(
            token: sequence,
            targetRenderedID: targetRenderedID,
            continuation: nil
        )
    }

    /// Consumes only the exact target lease whose command has crossed a native
    /// display frame (or whose opening settlement has physical proof). A newer
    /// command or direct user takeover retires the old lease first.
    func consumeTargetRelease() -> Bool {
        guard let token = targetReleaseToken,
              token == appliedTargetCommandToken,
              command == nil else { return false }
        if appliedTargetOrigin == .tailMaterialization,
           let releaseEvidence = targetReleaseEvidenceRevision,
           releaseEvidence != tailMaterializationEvidenceRevision {
            // Geometry changed after publication; re-enter settlement with the
            // exact sentinel still installed.
            targetReleaseToken = nil
            targetReleaseEvidenceRevision = nil
            scheduleTailMaterializationSettlementIfReady()
            return false
        }
        targetReleaseToken = nil
        targetReleaseEvidenceRevision = nil
        let pending = pendingTailMaterialization
        pendingTailMaterialization = nil
        if let pending, canAutomaticallyFollow {
            // Transfer the applied sentinel directly to the newest insertion.
            appliedTargetOrigin = .tailMaterialization
            prepareTailMaterialization(
                renderedID: pending.renderedID,
                layoutOwnerRenderedID: pending.layoutOwnerRenderedID,
                layoutTransactionID: pending.layoutTransactionID,
                layoutSettled: pending.layoutSettled
            )
            scheduleTailMaterializationSettlementIfReady()
            return false
        }
        appliedTargetCommandToken = nil
        appliedTargetOrigin = nil
        clearTailMaterializationState()
        // Re-evaluate marker evidence captured under the opening lease.
        schedulePhysicalTailRepairIfNeeded()
        return true
    }

    func openingRevealCompleted() {
        guard case .positioned(let context) = openingTailPhase,
              context.presentation == presentation else { return }
        openingTailPhase = .postReveal(.init(base: context))
        scheduleOpeningTailFrame()
    }

    func waitForOpeningTailSettlement() async {
        guard let token = openingTailToken else { return }
        let id = nextOpeningTailFinalWaiterID
        nextOpeningTailFinalWaiterID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if openingTailSettlementPending, openingTailToken == token {
                    openingTailFinalWaiters.append(.init(id: id, token: token, continuation: continuation))
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeOpeningTailFinalWaiter(id: id, token: token) }
        }
    }

    func requestCatchUp(reduceMotion: Bool) {
        cancelLayoutRestore()
        cancelCatchUp(restoringAnchored: false)
        if prepend != nil { finishPrepend(result: .discarded) }
        catchUpUnreadBeforeJump = hasUnreadContent
        viewportMode.reduce(.catchUpRequested)
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
            requiredGeometryRevision: geometryRevision
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

    func reconcileMaterializationRows(
        containsPhysicalRowID: (String) -> Bool
    ) {
        if let pending = pendingTailMaterialization,
           !containsPhysicalRowID(pending.renderedID) {
            pendingTailMaterialization = nil
        }
        guard let renderedID = tailMaterialization?.renderedID,
              !containsPhysicalRowID(renderedID) else { return }
        if let pending = pendingTailMaterialization,
           containsPhysicalRowID(pending.renderedID) {
            pendingTailMaterialization = nil
            if appliedTargetCommandToken != nil {
                appliedTargetOrigin = .tailMaterialization
            }
            prepareTailMaterialization(
                renderedID: pending.renderedID,
                layoutOwnerRenderedID: pending.layoutOwnerRenderedID,
                layoutTransactionID: pending.layoutTransactionID,
                layoutSettled: pending.layoutSettled
            )
            scheduleTailMaterializationSettlementIfReady()
            return
        }
        if command?.origin == .tailMaterialization {
            clearCommand()
        } else if appliedTargetCommandToken != nil,
                  appliedTargetOrigin == .tailMaterialization {
            // Canonical replacement retains the sentinel when lifecycle-row
            // geometry has not published.
            tailMaterialization?.renderedID = nil
            tailMaterialization?.requiredRevision = nil
            tailMaterialization?.requiredLayoutEpoch = nil
            scheduleTailMaterializationSettlementIfReady()
        } else {
            clearTailMaterializationState()
        }
    }

    func installedTranscriptChanged(_ installed: InstalledChatTranscript?) {
        guard var restore = layoutRestore else { return }
        guard let installed else { return }
        guard viewportMode == .anchored,
              let renderedID = installed.timeline.renderedIDBySemanticID[restore.anchor.semanticID] else {
            cancelLayoutRestore()
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
        viewportMode.reduce(.submitted)
    }

    /// Retains native viewport ownership and admits bounded repair from current
    /// same-presentation or fresh resumed marker evidence.
    func foregroundViewportBecameActive() {
        guard viewportMode == .pinned, !isUserInteracting else { return }
        retainedViewportReconciliationPending = true
        if catchUpPhase != .none {
            // Background suspension can interrupt before command application;
            // clear the whole catch-up owner so it cannot block later sends.
            cancelCatchUp(restoringAnchored: false)
        }
        // A ScrollPosition target is tied to the old native scroll tree. Retain
        // pinned intent, but retire that stale lease before the new tree emits
        // evidence; otherwise it can block repair or replay against a changed
        // content hierarchy. Detached readers never enter this branch.
        if command != nil || appliedTargetCommandToken != nil {
            clearCommand()
            retireAppliedTargetWithoutCallback()
            pinnedPositionRevision &+= 1
        }
        if physicalTailRepairCommandToken != nil {
            retireAppliedTargetWithoutCallback()
            pinnedPositionRevision &+= 1
        }
        // Native geometry can remain numerically unchanged while the backing
        // UIScrollView is rebuilt. Rebase the semantic epoch so the next
        // marker callback measures the new tree instead of trusting a stale
        // aligned sample from before suspension.
        advanceLayoutEpoch()
        geometryRevision &+= 1
        if openingTailPhase.isActive {
            scheduleOpeningTailFrame()
            return
        }
        // An existing command or target retains its original settlement owner.
        guard command == nil, appliedTargetCommandToken == nil,
              physicalTailRepairCommandToken == nil else { return }
        physicalTailRepairTask?.cancel()
        physicalTailRepairTask = nil
        physicalTailRepairEvidenceRevision = nil
        physicalTailRepairAttempts = 0
        physicalTailRepairFailedDisplacement = nil
        let currentEvidenceIsDisplaced = physicalTailEvidence.map {
            $0.presentationEpoch == presentation
                && $0.layoutEpoch == layoutEpoch
                && ($0.classification == .aboveViewport
                    || $0.classification == .belowViewport)
        } == true
        physicalTailRepairBlockedUntilEvidenceRevision = currentEvidenceIsDisplaced
            ? max(-1, semanticFrameRevision - 1)
            : semanticFrameRevision
        schedulePhysicalTailRepairIfNeeded()
    }

    @discardableResult
    func discreteTailInserted(
        renderedID: String,
        layoutTransactionID: Int? = nil
    ) -> Bool {
        guard !renderedID.isEmpty, canAutomaticallyFollow else { return false }
        if layoutTransactionID == nil,
           let index = preAdmissionSettledEntranceIDs.firstIndex(of: renderedID) {
            preAdmissionSettledEntranceIDs.remove(at: index)
        }
        if renderedID == tailMaterialization?.renderedID
            || renderedID == pendingTailMaterialization?.renderedID {
            return layoutTransactionID != nil
                && materializationLayoutTransactionID(for: renderedID) == layoutTransactionID
        }
        guard command == nil,
              appliedTargetCommandToken == nil,
              targetReleaseToken == nil,
              physicalTailRepairCommandToken == nil else {
            let existing = pendingTailMaterialization
            let ownsLayout = layoutTransactionID != nil
            pendingTailMaterialization = PendingTailMaterialization(
                renderedID: renderedID,
                layoutOwnerRenderedID: ownsLayout
                    ? renderedID
                    : existing?.layoutOwnerRenderedID,
                layoutTransactionID: layoutTransactionID
                    ?? existing?.layoutTransactionID,
                layoutSettled: ownsLayout
                    ? false
                    : existing?.layoutSettled ?? true
            )
            return true
        }
        beginTailMaterialization(
            renderedID: renderedID,
            layoutTransactionID: layoutTransactionID
        )
        return true
    }

    func layoutTransactionSettled(_ id: Int) {
        if tailMaterialization?.layoutTransactionID == id {
            tailMaterialization?.layoutSettled = true
            scheduleTailMaterializationSettlementIfReady()
        }
        if pendingTailMaterialization?.layoutTransactionID == id {
            pendingTailMaterialization?.layoutSettled = true
        }
    }

    /// Abandonment is a terminal cancellation, not successful layout evidence.
    /// Drop pending work owned by that generation and release any already-applied
    /// sentinel lease so a watchdog, background transition, or superseding
    /// presentation cannot strand the SwiftUI `ScrollPosition` target.
    func layoutTransactionAbandoned(_ id: Int) {
        if pendingTailMaterialization?.layoutTransactionID == id {
            pendingTailMaterialization = nil
        }
        guard tailMaterialization?.layoutTransactionID == id else { return }
        if command?.origin == .tailMaterialization {
            clearCommand()
            promotePendingTailMaterializationIfPossible()
            return
        }
        if appliedTargetOrigin == .tailMaterialization {
            requestAppliedTargetRelease(origin: .tailMaterialization)
        }
        clearTailMaterializationState()
    }

    func materializationLayoutTransactionID(for renderedID: String) -> Int? {
        if tailMaterialization?.layoutOwnerRenderedID == renderedID {
            return tailMaterialization?.layoutTransactionID
        }
        if pendingTailMaterialization?.layoutOwnerRenderedID == renderedID {
            return pendingTailMaterialization?.layoutTransactionID
        }
        return nil
    }

    /// Returns the exact admitted generation, or buffers this unique row's
    /// terminal entrance callback until admission. It never falls back to a
    /// current generation, so stale rows cannot settle newer layout work.
    func layoutTransactionForSettledEntrance(renderedID: String) -> Int? {
        if let generation = materializationLayoutTransactionID(for: renderedID) {
            return generation
        }
        guard !renderedID.isEmpty,
              !preAdmissionSettledEntranceIDs.contains(renderedID) else { return nil }
        preAdmissionSettledEntranceIDs.append(renderedID)
        if preAdmissionSettledEntranceIDs.count > 32 {
            preAdmissionSettledEntranceIDs.removeFirst(
                preAdmissionSettledEntranceIDs.count - 32
            )
        }
        return nil
    }

    func consumePreAdmissionEntranceSettlement(
        renderedID: String,
        layoutTransactionID: Int
    ) -> Bool {
        guard materializationLayoutTransactionID(for: renderedID) == layoutTransactionID,
              let index = preAdmissionSettledEntranceIDs.firstIndex(of: renderedID) else {
            return false
        }
        preAdmissionSettledEntranceIDs.remove(at: index)
        return true
    }

    private func promotePendingTailMaterializationIfPossible() {
        guard command == nil,
              appliedTargetCommandToken == nil,
              targetReleaseToken == nil,
              physicalTailRepairCommandToken == nil,
              canAutomaticallyFollow,
              let pending = pendingTailMaterialization else { return }
        pendingTailMaterialization = nil
        prepareTailMaterialization(
            renderedID: pending.renderedID,
            layoutOwnerRenderedID: pending.layoutOwnerRenderedID,
            layoutTransactionID: pending.layoutTransactionID,
            layoutSettled: pending.layoutSettled
        )
        publish(.tail, animation: .disabled, origin: .tailMaterialization)
    }

    private func beginTailMaterialization(
        renderedID: String,
        layoutTransactionID: Int?
    ) {
        prepareTailMaterialization(
            renderedID: renderedID,
            layoutOwnerRenderedID: layoutTransactionID == nil ? nil : renderedID,
            layoutTransactionID: layoutTransactionID,
            layoutSettled: layoutTransactionID == nil
        )
        // The stable sentinel preserves lazy-row identity through settlement.
        publish(.tail, animation: .disabled, origin: .tailMaterialization)
    }

    private func prepareTailMaterialization(
        renderedID: String,
        layoutOwnerRenderedID: String?,
        layoutTransactionID: Int?,
        layoutSettled: Bool
    ) {
        tailMaterializationSettlementTask?.cancel()
        tailMaterializationSettlementTask = nil
        let requiredRevision = semanticFrames[renderedID].map {
            max(0, $0.revision - 1)
        } ?? semanticFrameRevision
        tailMaterialization = TailMaterialization(
            renderedID: renderedID,
            requiredRevision: requiredRevision,
            requiredLayoutEpoch: layoutEpoch,
            layoutOwnerRenderedID: layoutOwnerRenderedID,
            layoutTransactionID: layoutTransactionID,
            layoutSettled: layoutSettled
        )
        targetReleaseEvidenceRevision = nil
        tailMaterializationEvidenceRevision &+= 1
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
        // opening retain stronger ownership and are rejected by the guard above.
        cancelLayoutRestore()
        clearCommand()
        let admittedAnchor = anchor.flatMap(admittedPrependAnchor)
        sequence &+= 1
        let token = sequence
        let admittedPresentation = presentation
        viewportMode.reduce(.prependBegan)
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
                #if HOSTED_TEST
                self.resumeHostedPrependSampleWaiters()
                #endif
            }
        }
        return true
    }

    private func admittedPrependAnchor(_ anchor: ChatSemanticAnchor) -> ChatSemanticAnchor? {
        guard anchor.layoutEpoch == layoutEpoch,
              let sample = semanticFrames[anchor.renderedID],
              sample.layoutEpoch == anchor.layoutEpoch,
              abs(sample.frame.minY - anchor.viewportOffsetY) <= 0.5,
              sample.frame.maxY > 0,
              sample.frame.minY < geometry.containerHeight else { return nil }
        return anchor
    }

    /// Applies exactly one currently-owned command. Its ScrollPosition target
    /// remains installed until the owning opening/catch-up/semantic transaction
    /// observes settlement, then a token-owned release callback removes it
    /// before ordinary native size-change anchoring resumes.
    @discardableResult
    func commandApplied(_ applied: ChatScrollCommand) -> Bool {
        guard command?.token == applied.token, applied.presentation == presentation else { return false }
        command = nil
        commandRevision &+= 1
        targetReleaseToken = nil
        appliedTargetCommandToken = applied.token
        appliedTargetOrigin = applied.origin
        if applied.origin == .tailMaterialization,
           let materialization = tailMaterialization,
           let renderedID = materialization.renderedID,
           let sample = semanticFrames[renderedID],
           sample.layoutEpoch == (materialization.requiredLayoutEpoch ?? layoutEpoch),
           sample.revision > (materialization.requiredRevision ?? -1) {
            // Fresh row evidence proves materialization; layout and stable-frame
            // evidence prove final geometry.
            scheduleTailMaterializationSettlementIfReady()
        }
        if applied.origin == .physicalTailRepair {
            // Application is not physical acknowledgement. Keep the target
            // lease until a newer, current marker frame proves alignment.
            physicalTailRepairCommandToken = applied.token
            physicalTailRepairIssuedEvidenceRevision = physicalTailEvidence?.semanticFrameRevision
            schedulePhysicalTailRepairAcknowledgement(
                token: applied.token,
                presentation: presentation,
                layout: layoutEpoch,
                issuedRevision: physicalTailRepairIssuedEvidenceRevision
            )
        }

        if openingTailPhase.context?.commandToken == applied.token { scheduleOpeningTailFrame() }
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
        return true
    }

    func cancel() {
        cancelAllOwnedWork(result: .cancelled)
        clearCommand()
    }

    private func evaluateLayoutRestoreIfReady() {
        guard var restore = layoutRestore, restore.readyForMeasurement,
              command == nil, restore.correctionCommandToken == nil,
              viewportMode == .anchored, !isUserInteracting,
              let renderedID = restore.renderedAnchorID,
              restore.expectedLayoutEpoch == layoutEpoch,
              let sample = semanticFrames[renderedID],
              sample.layoutEpoch == layoutEpoch,
              sample.revision > restore.requiredSampleRevision,
              geometryRevision > restore.requiredGeometryRevision else { return }
        restore.readyForMeasurement = false
        let residual = sample.frame.minY - restore.anchor.viewportOffsetY
        if abs(residual) <= 1 || restore.correctionCount >= 2 {
            cancelLayoutRestore()
            return
        }
        restore.correctionCount &+= 1
        let requested = Self.prependCorrectionOffset(
            currentOffsetY: geometry.offsetY,
            capturedViewportOffsetY: restore.anchor.viewportOffsetY,
            installedFrameMinY: sample.frame.minY
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
              let sample = semanticFrames[renderedID], sample.layoutEpoch == layoutEpoch,
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
        let requested = Self.prependCorrectionOffset(
            currentOffsetY: geometry.offsetY,
            capturedViewportOffsetY: anchor.viewportOffsetY,
            installedFrameMinY: sample.frame.minY
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

    private func beginOpeningTailSettlement(
        token: Int,
        targetRenderedID: String,
        continuation: CheckedContinuation<Bool, Never>?
    ) {
        let context = OpeningTailContext(
            token: token,
            targetRenderedID: targetRenderedID,
            targetSample: semanticFrames[targetRenderedID],
            presentation: presentation,
            commandToken: nil,
            commandSemanticRevision: nil,
            commandGeometryRevision: nil,
            commandAttemptCount: 0,
            positionedBestEffort: false
        )
        openingTailPhase = .positioning(context)
        openingTailContinuation = continuation
        scheduleOpeningTailTimeout(token: token, presentation: presentation)
        evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        if case .positioning = openingTailPhase { scheduleOpeningTailFrame() }
    }

    private func updateOpeningTargetSample(_ sample: SemanticFrameSample?) {
        switch openingTailPhase {
        case .positioning(var context):
            context.targetSample = sample
            openingTailPhase = .positioning(context)
        case .positioned(var context):
            context.targetSample = sample
            openingTailPhase = .positioned(context)
        case .postReveal(var context):
            context.base.targetSample = sample
            openingTailPhase = .postReveal(context)
        case .idle:
            break
        }
    }

    private func evaluateOpeningTailIfPossible(
        allowsUnrealizedTailCommand: Bool,
        schedulesPositionedFrame: Bool = true
    ) {
        guard let context = openingTailPhase.context,
              context.presentation == presentation else { return }
        let targetIsVisible = context.targetSample?.layoutEpoch == layoutEpoch
            && context.targetSample!.frame.maxY > 0
            && context.targetSample!.frame.minY < geometry.containerHeight
        let underflowLayoutIsInstalled = ChatTranscriptUnderflowLayoutPolicy
            .isPhysicallyInstalled(geometry)
        // Underflow has legal blank space below its content, so its eager marker
        // need only be freshly visible in the current layout. Overflow still
        // requires exact marker alignment. Requiring marker visibility in both
        // cases prevents a provisional height alone from exposing a blank view.
        let hasPhysicalTailProof = targetIsVisible
            && (underflowLayoutIsInstalled || openingTailEvidenceIsAligned)
        let physicallyPositioned = geometry.isPlausibleOpeningViewport
            && geometry.isAtCatchUpBoundary
            && hasPhysicalTailProof
        if physicallyPositioned {
            switch openingTailPhase {
            case .positioning(var value):
                clearOpeningCommand(matching: value.commandToken)
                value.commandToken = nil
                openingTailPhase = .positioned(value)
                openingTailTimeoutTask?.cancel()
                openingTailTimeoutTask = nil
                let continuation = openingTailContinuation
                openingTailContinuation = nil
                continuation?.resume(returning: true)
            case .postReveal:
                if schedulesPositionedFrame { scheduleOpeningTailFrame() }
            case .positioned, .idle:
                break
            }
            return
        }
        guard case .positioning(let value) = openingTailPhase else { return }
        if let commandToken = value.commandToken {
            let fresh = semanticFrameRevision > (value.commandSemanticRevision ?? semanticFrameRevision)
                || geometryRevision > (value.commandGeometryRevision ?? geometryRevision)
            if fresh, command?.token != commandToken { scheduleOpeningTailFrame() }
            return
        }
        guard viewportMode == .pinned, !isUserInteracting, command == nil,
              value.targetSample?.layoutEpoch == layoutEpoch || allowsUnrealizedTailCommand,
              geometry.isValid || allowsUnrealizedTailCommand else { return }
        publish(.openingTail(value.targetRenderedID), animation: .disabled, origin: .presentation)
        var updated = value
        updated.commandToken = command?.token
        updated.commandSemanticRevision = semanticFrameRevision
        updated.commandGeometryRevision = geometryRevision
        updated.commandAttemptCount &+= 1
        openingTailPhase = .positioning(updated)
    }

    private func scheduleOpeningTailFrame() {
        guard let context = openingTailPhase.context,
              context.presentation == presentation else { return }
        openingTailFrameTask?.cancel()
        openingTailFrameTaskGeneration &+= 1
        let generation = openingTailFrameTaskGeneration
        let token = context.token
        let admittedPresentation = context.presentation
        let semanticRevision = semanticFrameRevision
        let admittedGeometryRevision = geometryRevision
        openingTailFrameTask = Task { [weak self, frameScheduler] in
            do { try await frameScheduler.nextFrame(); try Task.checkCancellation() }
            catch { return }
            guard let self, self.openingTailFrameTaskGeneration == generation,
                  self.openingTailPhase.context?.token == token,
                  self.openingTailPhase.context?.presentation == admittedPresentation else { return }
            self.openingTailFrameTask = nil
            if case .positioning(var value) = self.openingTailPhase,
               let commandToken = value.commandToken,
               self.command?.token != commandToken {
                let fresh = self.semanticFrameRevision > (value.commandSemanticRevision ?? self.semanticFrameRevision)
                    || self.geometryRevision > (value.commandGeometryRevision ?? self.geometryRevision)
                if fresh || value.commandAttemptCount < 2 {
                    value.commandToken = nil
                    value.commandSemanticRevision = nil
                    value.commandGeometryRevision = nil
                    self.openingTailPhase = .positioning(value)
                }
            }
            self.evaluateOpeningTailIfPossible(
                allowsUnrealizedTailCommand: true,
                schedulesPositionedFrame: false
            )
            guard case .postReveal(var value) = self.openingTailPhase else { return }
            let stable = self.semanticFrameRevision == semanticRevision
                && self.geometryRevision == admittedGeometryRevision
                && (value.base.positionedBestEffort || self.openingTailViewportIsPhysicallySettled)
            if stable {
                value.stableFrameCount &+= 1
                self.openingTailPhase = .postReveal(value)
                if value.stableFrameCount >= 2 { self.finishOpeningTailSettlement() }
                else { self.scheduleOpeningTailFrame() }
            } else {
                value.stableFrameCount = 0
                self.openingTailPhase = .postReveal(value)
                self.scheduleOpeningTailFrame()
            }
        }
    }

    /// During the opaque opening, the transcript stack is intentionally lifted
    /// eight points for the reveal. Marker geometry therefore proves the tail
    /// when it is aligned to the lifted viewport as well as at its settled
    /// position; this exception is opening-only and cannot arm physical repair.
    private var openingTailEvidenceIsAligned: Bool {
        guard let evidence = physicalTailEvidence,
              evidence.presentationEpoch == presentation,
              evidence.layoutEpoch == layoutEpoch else { return false }
        if evidence.classification == .aligned { return true }
        return openingTailPhase.isActive && abs(evidence.signedDisplacement - 8) <= 2
    }

    private var openingTailViewportIsPhysicallySettled: Bool {
        guard geometry.isPlausibleOpeningViewport,
              geometry.isAtCatchUpBoundary else { return false }
        guard let sample = openingTailPhase.context?.targetSample,
              sample.layoutEpoch == layoutEpoch else { return false }
        let targetIsVisible = sample.frame.maxY > 0
            && sample.frame.minY < geometry.containerHeight
        let underflowLayoutIsInstalled = ChatTranscriptUnderflowLayoutPolicy
            .isPhysicallyInstalled(geometry)
        return targetIsVisible
            && (underflowLayoutIsInstalled || openingTailEvidenceIsAligned)
    }

    private func finishOpeningTailSettlement() {
        let token = openingTailToken
        let commandToken = appliedTargetCommandToken
        openingTailTimeoutTask?.cancel()
        openingTailTimeoutTask = nil
        openingTailFrameTaskGeneration &+= 1
        openingTailFrameTask?.cancel()
        openingTailFrameTask = nil
        requestTargetRelease(commandToken)
        openingTailPhase = .idle
        openingTailContinuation?.resume(returning: true)
        openingTailContinuation = nil
        if let token { resumeOpeningTailFinalWaiters(token: token) }
        viewportMode.reduce(.opened)
        isAtBottom = true
        tailSettlementGeneration &+= 1
        // The marker frame observed while the transcript is lifted by the
        // opening reveal is intentionally not repair evidence. Wait for the
        // first post-reveal marker sample before admitting physical repair.
        physicalTailRepairBlockedUntilEvidenceRevision = semanticFrameRevision
        schedulePhysicalTailRepairIfNeeded()
    }

    private func clearOpeningCommand(matching token: Int?) {
        guard let token, command?.token == token else { return }
        clearCommand()
    }

    private func clearOpeningTailSettlement(
        ifToken expectedToken: Int? = nil,
        ifPresentation expectedPresentation: Int? = nil,
        positioningSucceeded: Bool = false
    ) {
        if let expectedToken, openingTailToken != expectedToken { return }
        if let expectedPresentation, openingTailPresentation != expectedPresentation { return }
        let token = openingTailToken
        openingTailTimeoutTask?.cancel()
        openingTailTimeoutTask = nil
        openingTailFrameTaskGeneration &+= 1
        openingTailFrameTask?.cancel()
        openingTailFrameTask = nil
        if let commandToken = openingTailPhase.context?.commandToken,
           command?.token == commandToken { clearCommand() }
        retireAppliedTargetWithoutCallback()
        openingTailPhase = .idle
        openingTailContinuation?.resume(returning: positioningSucceeded)
        openingTailContinuation = nil
        if let token { resumeOpeningTailFinalWaiters(token: token) }
    }

    private func scheduleOpeningTailTimeout(token: Int, presentation: Int) {
        openingTailTimeoutTask?.cancel()
        openingTailTimeoutTask = Task { [weak self, clock, openingTailTimeout] in
            do { try await clock.sleep(openingTailTimeout); try Task.checkCancellation() }
            catch { return }
            guard let self, case .positioning(let value) = self.openingTailPhase,
                  value.token == token, value.presentation == presentation else { return }

            // A deadline is a failure boundary, never physical proof. A
            // command that crossed the native application boundary cannot be
            // safely replayed while its target is still installed, so fail the
            // bounded opening rather than revealing an unverified viewport.
            self.clearOpeningCommand(matching: value.commandToken)
            self.failOpeningTailPositioning()
        }
    }

    private func failOpeningTailPositioning() {
        let token = openingTailToken
        openingTailTimeoutTask?.cancel()
        openingTailTimeoutTask = nil
        openingTailFrameTaskGeneration &+= 1
        openingTailFrameTask?.cancel()
        openingTailFrameTask = nil
        if let commandToken = openingTailPhase.context?.commandToken,
           command?.token == commandToken {
            clearCommand()
        }
        retireAppliedTargetWithoutCallback()
        openingTailPhase = .idle
        openingTailContinuation?.resume(returning: false)
        openingTailContinuation = nil
        if let token { resumeOpeningTailFinalWaiters(token: token) }
    }

    private func resumeOpeningTailFinalWaiter(id: Int, token: Int) {
        guard let index = openingTailFinalWaiters.firstIndex(where: { $0.id == id && $0.token == token }) else { return }
        openingTailFinalWaiters.remove(at: index).continuation.resume()
    }

    private func resumeOpeningTailFinalWaiters(token: Int) {
        let waiters = openingTailFinalWaiters.filter { $0.token == token }
        openingTailFinalWaiters.removeAll { $0.token == token }
        waiters.forEach { $0.continuation.resume() }
    }

    private func pinAtTail() {
        let changed = viewportMode == .anchored || !isAtBottom
        viewportMode.reduce(.userReturnedToTail)
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
            viewportMode.reduce(.userTookOver)
            isAtBottom = false
            hasUnreadContent = catchUpUnreadBeforeJump || hasUnreadContent
        }
        catchUpUnreadBeforeJump = false
    }

    private func beginDirectInteraction(allowsBottomRubberBand: Bool = true) {
        retainedViewportReconciliationPending = false
        physicalTailRepairTask?.cancel()
        physicalTailRepairTask = nil
        physicalTailRepairEvidenceRevision = nil
        physicalTailRepairCommandToken = nil
        physicalTailRepairIssuedEvidenceRevision = nil
        physicalTailRepairFailedDisplacement = nil
        retireAppliedTargetWithoutCallback()
        let isBottomRubberBand = allowsBottomRubberBand
            && viewportMode == .pinned
            && geometry.isValid
            && (geometry.isAtCatchUpBoundary || geometry.isPastBottomEdge)
        if !isBottomRubberBand {
            viewportMode.reduce(.userTookOver)
            isAtBottom = false
        }
        abandonAutomaticTransactionsForDirectInteraction()
    }

    private func abandonAutomaticTransactionsForDirectInteraction() {
        clearOpeningTailSettlement()
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
        viewportMode.reduce(.prependEnded)
        #if HOSTED_TEST
        cancelHostedPrependSampleWaiters()
        #endif
        context.completion(result)
    }

    private func cancelAllOwnedWork(result: PerformanceResult) {
        physicalTailRepairTask?.cancel()
        physicalTailRepairTask = nil
        physicalTailRepairEvidenceRevision = nil
        physicalTailRepairCommandToken = nil
        physicalTailRepairIssuedEvidenceRevision = nil
        physicalTailRepairFailedDisplacement = nil
        physicalTailRepairBlockedUntilEvidenceRevision = nil
        pendingTailMaterialization = nil
        preAdmissionSettledEntranceIDs.removeAll(keepingCapacity: true)
        tailMaterializationSettlementTask?.cancel()
        tailMaterializationSettlementTask = nil
        retireAppliedTargetWithoutCallback()
        clearOpeningTailSettlement()
        cancelLayoutRestore()
        cancelCatchUp(restoringAnchored: false)
        prependTask?.cancel()
        prependTimeoutTask?.cancel()
        if let completion = prepend?.completion { completion(result) }
        prependTask = nil
        prependTimeoutTask = nil
        prepend = nil
        #if HOSTED_TEST
        cancelHostedPrependSampleWaiters()
        #endif
    }

    private func tailMaterializationEvidenceChanged() {
        tailMaterializationEvidenceRevision &+= 1
        tailMaterializationSettlementTask?.cancel()
        tailMaterializationSettlementTask = nil
        scheduleTailMaterializationSettlementIfReady()
    }

    private func scheduleTailMaterializationSettlementIfReady() {
        guard tailMaterializationSettlementTask == nil,
              let materialization = tailMaterialization,
              materialization.layoutSettled,
              command == nil,
              appliedTargetOrigin == .tailMaterialization,
              let token = appliedTargetCommandToken,
              targetReleaseToken == nil,
              materialization.requiredLayoutEpoch == nil
                || materialization.requiredLayoutEpoch == layoutEpoch else { return }
        guard let physicalEvidence = physicalTailEvidence,
              physicalEvidence.presentationEpoch == presentation,
              physicalEvidence.layoutEpoch == layoutEpoch,
              physicalEvidence.classification == .aligned else { return }
        if let renderedID = materialization.renderedID {
            // Row and marker callbacks are independent native observations; the
            // marker may arrive first. Require both fresh samples, not an
            // artificial ordering between their revisions.
            guard let sample = semanticFrames[renderedID],
                  sample.layoutEpoch == layoutEpoch,
                  sample.revision > (materialization.requiredRevision ?? -1) else { return }
        }
        let admittedPresentation = presentation
        let admittedLayoutEpoch = layoutEpoch
        let evidenceRevision = tailMaterializationEvidenceRevision
        tailMaterializationSettlementTask = Task { [weak self, frameScheduler] in
            do {
                try await frameScheduler.nextFrame()
                try Task.checkCancellation()
                try await frameScheduler.nextFrame()
                try Task.checkCancellation()
            } catch { return }
            guard let self,
                  self.presentation == admittedPresentation,
                  self.layoutEpoch == admittedLayoutEpoch,
                  self.appliedTargetCommandToken == token,
                  self.appliedTargetOrigin == .tailMaterialization,
                  self.command == nil,
                  self.tailMaterializationEvidenceRevision == evidenceRevision else { return }
            self.tailMaterializationSettlementTask = nil
            // Publish release after participant completion and two unchanged
            // display boundaries; consumption revalidates this evidence.
            self.requestTargetRelease(token)
        }
    }

    private func clearTailMaterializationState() {
        tailMaterializationSettlementTask?.cancel()
        tailMaterializationSettlementTask = nil
        tailMaterialization = nil
        targetReleaseEvidenceRevision = nil
    }

    private func requestTargetRelease(_ token: Int?) {
        guard let token,
              command == nil,
              appliedTargetCommandToken == token,
              targetReleaseToken != token else { return }
        targetReleaseTask?.cancel()
        targetReleaseToken = token
        let admittedPresentation = presentation
        let admittedLayoutEpoch = appliedTargetOrigin == .tailMaterialization
            ? layoutEpoch
            : nil
        let admittedEvidenceRevision = appliedTargetOrigin == .tailMaterialization
            ? tailMaterializationEvidenceRevision
            : nil
        targetReleaseTask = Task { [weak self, frameScheduler] in
            do { try await frameScheduler.nextFrame(); try Task.checkCancellation() }
            catch { return }
            guard let self,
                  self.presentation == admittedPresentation,
                  admittedLayoutEpoch == nil || self.layoutEpoch == admittedLayoutEpoch,
                  self.command == nil,
                  self.appliedTargetCommandToken == token,
                  self.targetReleaseToken == token else { return }
            self.targetReleaseTask = nil
            self.targetReleaseEvidenceRevision = admittedEvidenceRevision
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
        targetReleaseEvidenceRevision = nil
        appliedTargetCommandToken = nil
        appliedTargetOrigin = nil
        clearTailMaterializationState()
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
        #if HOSTED_TEST
        let waiters = hostedCommandWaiters
        hostedCommandWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: command!) }
        #endif
    }

    private func clearCommand() {
        guard let command else { return }
        if command.origin == .tailMaterialization {
            clearTailMaterializationState()
        }
        self.command = nil
        commandRevision &+= 1
    }

    private func advanceLayoutEpoch() {
        layoutEpoch &+= 1
        // A pending materialization command can outlive a projection install.
        // Rebase its evidence before application so the command cannot be
        // permanently rejected as belonging to the prior layout epoch.
        if command?.origin == .tailMaterialization {
            tailMaterialization?.requiredLayoutEpoch = layoutEpoch
            tailMaterialization?.requiredRevision = semanticFrameRevision
            tailMaterializationEvidenceRevision &+= 1
        }
        // Materialization leases require evidence from the current layout epoch.
        if command?.origin == .physicalTailRepair {
            clearCommand()
        }
        if appliedTargetOrigin == .physicalTailRepair {
            // Projection installation invalidates the native target tree. Retire
            // the applied repair target atomically so its cancelled acknowledgement
            // cannot strand ScrollPosition ownership across the new layout.
            retireAppliedTargetWithoutCallback()
            pinnedPositionRevision &+= 1
        }
        if appliedTargetOrigin == .tailMaterialization {
            targetReleaseTask?.cancel()
            targetReleaseTask = nil
            targetReleaseToken = nil
            targetReleaseEvidenceRevision = nil
            tailMaterializationSettlementTask?.cancel()
            tailMaterializationSettlementTask = nil
            tailMaterialization?.requiredLayoutEpoch = layoutEpoch
            tailMaterialization?.requiredRevision = semanticFrameRevision
            tailMaterializationEvidenceRevision &+= 1
        }
        physicalTailRepairTask?.cancel()
        physicalTailRepairTask = nil
        physicalTailRepairAttempts = 0
        physicalTailRepairEvidenceRevision = nil
        physicalTailRepairCommandToken = nil
        physicalTailRepairIssuedEvidenceRevision = nil
        physicalTailRepairFailedDisplacement = nil
        physicalTailRepairBlockedUntilEvidenceRevision = nil
        // Preserve an admitted pending insertion across an epoch change. The
        // projection reconciliation callback still removes it when its exact
        // row disappears; dropping it here would strand the active sentinel.
        physicalTailEvidence = nil
        semanticFrames.removeAll(keepingCapacity: true)
    }

    private func refreshPhysicalTailEvidence(markerFrame: CGRect) {
        // Marker frames and visible bounds share viewport-relative coordinates.
        let visibleBounds = geometry.containerHeight > 0 && geometry.containerHeight.isFinite
            ? CGRect(x: 0, y: 0, width: 1, height: geometry.containerHeight)
            : nil
        let previousClassification = physicalTailEvidence?.classification
        let evidence = ChatPhysicalTailEvidence.make(
            presentationEpoch: presentation,
            layoutEpoch: layoutEpoch,
            semanticFrameRevision: semanticFrameRevision,
            markerFrame: markerFrame,
            visibleBounds: visibleBounds
        )
        guard evidence != physicalTailEvidence else { return }
        physicalTailRepairTask?.cancel()
        physicalTailRepairTask = nil
        physicalTailRepairEvidenceRevision = nil
        physicalTailEvidence = evidence
        if evidence.classification == .aligned, previousClassification != .aligned {
            // A settled alignment starts a fresh bounded repair budget.
            physicalTailRepairAttempts = 0
            physicalTailRepairFailedDisplacement = nil
        } else if let failed = physicalTailRepairFailedDisplacement,
                  (evidence.classification == .belowViewport
                    || evidence.classification == .aboveViewport),
                  abs(evidence.signedDisplacement - failed) > 2 {
            // A materially new displacement starts a fresh bounded lease.
            physicalTailRepairAttempts = 0
            physicalTailRepairFailedDisplacement = nil
        }
        if let token = physicalTailRepairCommandToken {
            let isAcknowledged = evidence.classification == .aligned
                && evidence.semanticFrameRevision
                    > (physicalTailRepairIssuedEvidenceRevision ?? -1)
            if isAcknowledged {
                physicalTailRepairCommandToken = nil
                physicalTailRepairIssuedEvidenceRevision = nil
                physicalTailRepairTask?.cancel()
                physicalTailRepairTask = nil
                requestTargetRelease(token)
            } else {
                schedulePhysicalTailRepairAcknowledgement(
                    token: token,
                    presentation: presentation,
                    layout: layoutEpoch,
                    issuedRevision: physicalTailRepairIssuedEvidenceRevision
                )
            }
            return
        }
        schedulePhysicalTailRepairIfNeeded()
    }

    private func schedulePhysicalTailRepairIfNeeded() {
        guard let evidence = physicalTailEvidence,
              evidence.presentationEpoch == presentation,
              evidence.layoutEpoch == layoutEpoch,
              (evidence.classification == .belowViewport
                  || evidence.classification == .aboveViewport),
              viewportMode == .pinned,
              !isUserInteracting, !directPositionOwnership,
              command == nil, appliedTargetCommandToken == nil,
              physicalTailRepairCommandToken == nil,
              prepend == nil, layoutRestore == nil,
              catchUpPhase == .none, !openingTailPhase.isActive,
              physicalTailRepairAttempts < 2 else {
            physicalTailRepairTask?.cancel()
            physicalTailRepairTask = nil
            return
        }
        guard evidence.semanticFrameRevision
                > (physicalTailRepairBlockedUntilEvidenceRevision ?? -1) else {
            physicalTailRepairTask?.cancel()
            physicalTailRepairTask = nil
            return
        }
        guard physicalTailRepairEvidenceRevision != evidence.semanticFrameRevision,
              physicalTailRepairTask == nil else { return }
        physicalTailRepairEvidenceRevision = evidence.semanticFrameRevision
        let admittedPresentation = presentation
        let admittedLayout = layoutEpoch
        let admittedRevision = evidence.semanticFrameRevision
        physicalTailRepairTask = Task { [weak self, frameScheduler] in
            do { try await frameScheduler.nextFrame(); try Task.checkCancellation() }
            catch { return }
            guard let self,
                  self.presentation == admittedPresentation,
                  self.layoutEpoch == admittedLayout,
                  self.physicalTailEvidence?.semanticFrameRevision == admittedRevision else { return }
            self.physicalTailRepairTask = nil
            guard let current = self.physicalTailEvidence,
                  (current.classification == .belowViewport
                      || current.classification == .aboveViewport),
                  self.viewportMode == .pinned,
                  !self.isUserInteracting, !self.directPositionOwnership,
                  self.command == nil, self.appliedTargetCommandToken == nil,
                  self.physicalTailRepairCommandToken == nil,
                  self.prepend == nil, self.layoutRestore == nil,
                  self.catchUpPhase == .none, !self.openingTailPhase.isActive,
                  self.physicalTailRepairAttempts < 2 else { return }
            self.physicalTailRepairAttempts &+= 1
            self.publish(.tail, animation: .disabled, origin: .physicalTailRepair)
        }
    }

    private func schedulePhysicalTailRepairAcknowledgement(
        token: Int,
        presentation: Int,
        layout: Int,
        issuedRevision: Int?
    ) {
        physicalTailRepairTask?.cancel()
        physicalTailRepairTask = Task { [weak self, frameScheduler] in
            do { try await frameScheduler.nextFrame(); try Task.checkCancellation() }
            catch { return }
            guard let self,
                  self.physicalTailRepairCommandToken == token,
                  self.presentation == presentation,
                  self.layoutEpoch == layout else { return }
            self.physicalTailRepairTask = nil
            let hasNewEvidence = if let revision = self.physicalTailEvidence?.semanticFrameRevision {
                revision > (issuedRevision ?? -1)
            } else {
                false
            }
            let aligned = self.physicalTailEvidence?.classification == .aligned && hasNewEvidence
            if aligned {
                self.physicalTailRepairCommandToken = nil
                self.physicalTailRepairIssuedEvidenceRevision = nil
                self.requestTargetRelease(token)
                return
            }
            // A retry is admitted only for a newer settling marker frame. If
            // no exact acknowledgement arrived, retire the lease rather than
            // issuing a recurring tail command.
            guard hasNewEvidence, self.physicalTailRepairAttempts < 2,
                  (self.physicalTailEvidence?.classification == .belowViewport
                    || self.physicalTailEvidence?.classification == .aboveViewport) else {
                self.physicalTailRepairCommandToken = nil
                self.physicalTailRepairIssuedEvidenceRevision = nil
                self.physicalTailRepairFailedDisplacement =
                    self.physicalTailEvidence?.signedDisplacement
                self.retireAppliedTargetWithoutCallback()
                // Do not leave a stale target silently owning the ready view.
                // One target-free pinned revision lets SwiftUI rebase its native
                // scroll tree; later fresh marker evidence may admit the bounded
                // repair budget again without creating a command loop.
                self.retainedViewportReconciliationPending = true
                self.pinnedPositionRevision &+= 1
                return
            }
            self.physicalTailRepairCommandToken = nil
            self.physicalTailRepairIssuedEvidenceRevision = nil
            self.retireAppliedTargetWithoutCallback()
            self.physicalTailRepairAttempts &+= 1
            self.publish(.tail, animation: .disabled, origin: .physicalTailRepair)
        }
    }

    #if HOSTED_TEST
    var hostedSemanticFrameCount: Int { semanticFrames.count }

    func hostedNextCommand() async throws -> ChatScrollCommand {
        if let command { return command }
        let id = nextHostedCommandWaiterID
        nextHostedCommandWaiterID &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { hostedCommandWaiters.append(.init(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelHostedCommandWaiter(id: id) }
        }
    }

    func hostedWaitForPrependSemanticSample() async throws {
        if isWaitingForPrependSemanticFrame { return }
        let id = nextHostedPrependSampleWaiterID
        nextHostedPrependSampleWaiterID &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { hostedPrependSampleWaiters.append(.init(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelHostedPrependSampleWaiter(id: id) }
        }
    }

    private func resumeHostedPrependSampleWaiters() {
        let waiters = hostedPrependSampleWaiters
        hostedPrependSampleWaiters.removeAll()
        waiters.forEach { $0.continuation.resume() }
    }

    private func cancelHostedPrependSampleWaiters() {
        let waiters = hostedPrependSampleWaiters
        hostedPrependSampleWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    private func cancelHostedPrependSampleWaiter(id: Int) {
        guard let index = hostedPrependSampleWaiters.firstIndex(where: { $0.id == id }) else { return }
        hostedPrependSampleWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelHostedCommandWaiter(id: Int) {
        guard let index = hostedCommandWaiters.firstIndex(where: { $0.id == id }) else { return }
        hostedCommandWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    #endif

    nonisolated static func prependCorrectionOffset(
        currentOffsetY: CGFloat,
        capturedViewportOffsetY: CGFloat,
        installedFrameMinY: CGFloat
    ) -> CGFloat {
        max(0, currentOffsetY + installedFrameMinY - capturedViewportOffsetY)
    }

    private static func isDirectUserPhase(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .tracking || phase == .decelerating
    }
}
