import SwiftUI

enum ChatScrollAnimation: Equatable, Sendable {
    case disabled
    case smooth(duration: Double)
}

struct ChatScrollCommand: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case presentation
        case automaticFollow
        case catchUp
        case layout
        case prepend
        case binding
    }

    enum Destination: Equatable, Sendable {
        case resetToBottom
        case tail
        case openingTail(String)
        case offsetY(CGFloat)
        case releaseBinding
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

/// Sole owner of transcript geometry/semantic-frame intake and every
/// app-generated scroll command. The view only executes and acknowledges typed
/// commands; direct/native/accessibility interaction always wins.
@Observable
@MainActor
final class ChatScrollCoordinator {
    private struct SemanticFrameSample: Equatable {
        let layoutEpoch: Int
        let revision: Int
        let frame: CGRect
    }

    private struct OpeningTailFinalWaiter {
        let id: Int
        let token: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private enum CatchUpPhase: Equatable {
        case none
        case staged
        case final
        case settling
    }

    private(set) var isAtBottom = true
    private(set) var userScrolledAway = false
    private(set) var hasUnreadContent = false
    private(set) var isUserInteracting = false
    private(set) var isScrollAnimating = false
    private(set) var isPrependingHistory = false
    private(set) var command: ChatScrollCommand?
    private(set) var commandRevision = 0
    private(set) var layoutEpoch = 0
    private(set) var tailSettlementGeneration = 0
    private(set) var maximumPrependSemanticExcursion: CGFloat = 0

    private let frameScheduler: DisplayFrameScheduler
    private var presentation = 0
    private var sequence = 0
    private var geometry = ChatTranscriptGeometry.zero
    private var semanticFrames: [String: SemanticFrameSample] = [:]
    private var semanticFrameOrder: [String] = []
    private var semanticFrameRevision = 0

    private var isNativeUserOwned = false
    private var pendingNativeUserGeometry = false
    private var hadUserInteraction = false
    private var isUserDrivenSettling = false
    private var directTailReturnArmed = false
    private var boundaryCameFromViewportWithoutTailMovement = false
    private var pendingGrowthFollow = false
    private var pendingContinuousGrowthFollow = false
    private var discreteFollowRenderedIDs: Set<String> = []
    private var discreteFollowRenderedIDOrder: [String] = []
    private var pendingUnattributedOlderMovement = false
    private var userInteractionStartOffsetY: CGFloat?
    private var userInteractionStartDistanceFromBottom: CGFloat?
    private var bindingIsReleased = false
    private var openingTailSettlementPending = false
    private var openingTailToken: Int?
    private var openingTailTargetRenderedID: String?
    private var openingTailTargetSample: SemanticFrameSample?
    private var openingTailPresentation: Int?
    private var openingTailCommandToken: Int?
    private var openingTailCommandSemanticRevision: Int?
    private var openingTailCommandGeometryRevision: Int?
    private var openingTailCommandAttemptCount = 0
    private var openingTailPositioned = false
    private var openingTailRevealCompleted = false
    private var openingTailStableFrameCount = 0
    private var openingTailStableSemanticRevision: Int?
    private var openingTailStableGeometryRevision: Int?
    private var openingTailContinuation: CheckedContinuation<Bool, Never>?
    private var openingTailFinalWaiters: [OpeningTailFinalWaiter] = []
    private var nextOpeningTailFinalWaiterID = 0
    private var openingTailFrameTaskGeneration = 0
    private var geometryRevision = 0

    @ObservationIgnored private var followFrameTask: Task<Void, Never>?
    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    @ObservationIgnored private var prependTask: Task<Void, Never>?
    @ObservationIgnored private var openingTailFrameTask: Task<Void, Never>?

    private var catchUpPhase: CatchUpPhase = .none
    private var catchUpCommandToken: Int?
    private var catchUpUnreadBeforeJump = false

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
    @ObservationIgnored private var hostedFollowDecisionWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextHostedCommandWaiterID = 0
    private var nextHostedPrependSampleWaiterID = 0
    private(set) var hostedFollowDecisionRevision = 0
    #endif

    private var layoutMutationAnchor: ChatSemanticAnchor?
    private var layoutMutationWasDetached = false
    private var layoutMutationPendingInstall = false
    private var layoutMutationRenderedAnchorID: String?
    private var layoutMutationExpectedLayoutEpoch: Int?
    private var layoutMutationRequiredSampleRevision = 0
    private var layoutMutationRequiredGeometryRevision = 0
    private var layoutMutationReadyForMeasurement = false
    private var layoutMutationCorrectionCount = 0
    private var layoutMutationCorrectionCommandToken: Int?
    private var layoutMutationAppliedOffset = false
    private var pendingInstalledTailSettlement = false

    private var prependToken: Int?
    private var prependWasScrolledAway = false
    private var prependInterrupted = false
    private var prependAnchor: ChatSemanticAnchor?
    private var prependRenderedAnchorID: String?
    private var prependExpectedLayoutEpoch: Int?
    private var prependReadyForMeasurement = false
    private var prependRequiredSampleRevision = 0
    private var prependRequiredGeometryRevision = 0
    private var prependCorrectionCount = 0
    private var prependCorrectionCommandToken: Int?
    private var prependAppliedOffset = false
    private var prependCompletion: (@MainActor (PerformanceResult) -> Void)?

    init(frameScheduler: DisplayFrameScheduler = .displayLink) {
        self.frameScheduler = frameScheduler
    }

    /// The catch-up affordance projects one fact only: the reader has
    /// intentionally left the latest tail. Unread events, native binding
    /// ownership, and issued commands cannot keep the button visible.
    var shouldShowCatchUpButton: Bool { userScrolledAway }

    var shouldTrackUnreadResponse: Bool {
        userScrolledAway || catchUpPhase != .none
    }

    var isWaitingForPrependSemanticFrame: Bool {
        isPrependingHistory && prependReadyForMeasurement && prependCorrectionCommandToken == nil
    }

    var canAutomaticallyFollow: Bool {
        !userScrolledAway && !isUserInteracting && !isNativeUserOwned
            && !pendingNativeUserGeometry && !isUserDrivenSettling
            && !isPrependingHistory && catchUpPhase == .none
    }

    func resetForPresentation(_ presentation: Int? = nil) {
        cancelAllOwnedWork(result: .discarded)
        self.presentation = presentation ?? (self.presentation &+ 1)
        isAtBottom = true
        userScrolledAway = false
        hasUnreadContent = false
        isUserInteracting = false
        isScrollAnimating = false
        isNativeUserOwned = false
        pendingNativeUserGeometry = false
        hadUserInteraction = false
        isUserDrivenSettling = false
        directTailReturnArmed = false
        boundaryCameFromViewportWithoutTailMovement = false
        pendingGrowthFollow = false
        pendingContinuousGrowthFollow = false
        pendingUnattributedOlderMovement = false
        userInteractionStartOffsetY = nil
        userInteractionStartDistanceFromBottom = nil
        geometry = .zero
        geometryRevision = 0
        advanceLayoutEpoch()
        bindingIsReleased = false
        clearOpeningTailSettlement()
        clearCommand()
        publish(.resetToBottom, animation: .disabled, origin: .presentation)
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
        semanticFrames[renderedID] = .init(
            layoutEpoch: layoutEpoch,
            revision: semanticFrameRevision,
            frame: frame
        )
        semanticFrameOrder.removeAll { $0 == renderedID }
        semanticFrameOrder.append(renderedID)
        if semanticFrameOrder.count > 256 {
            let overflow = semanticFrameOrder.count - 256
            let removed = Array(semanticFrameOrder.prefix(overflow))
            semanticFrameOrder.removeFirst(overflow)
            for id in removed { semanticFrames[id] = nil }
        }
        recordPrependExcursionIfOwned(renderedID: renderedID, layoutEpoch: layoutEpoch, frame: frame)
        evaluateLayoutMutationIfReady()
        evaluatePrependMeasurementIfReady()
        if openingTailSettlementPending,
           openingTailPresentation == presentation,
           openingTailTargetRenderedID == renderedID {
            openingTailTargetSample = semanticFrames[renderedID]
            evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        }
    }

    /// Chooses the visually first measured row that actually intersects the
    /// viewport. Visibility thresholds are deliberately not authority.
    func semanticAnchor(in timeline: ChatTranscriptTimeline) -> ChatSemanticAnchor? {
        let candidates = timeline.ids.compactMap { renderedID -> (String, String, CGRect)? in
            guard let semanticID = timeline.preferredSemanticIDByRenderedID[renderedID],
                  let sample = semanticFrames[renderedID],
                  sample.layoutEpoch == layoutEpoch,
                  sample.frame.maxY > 0,
                  sample.frame.minY < geometry.containerHeight else { return nil }
            return (renderedID, semanticID, sample.frame)
        }
        guard let selected = candidates.min(by: { left, right in
            if left.2.minY != right.2.minY { return left.2.minY < right.2.minY }
            return timeline.ids.firstIndex(of: left.0) ?? 0 < timeline.ids.firstIndex(of: right.0) ?? 0
        }) else { return nil }
        return ChatSemanticAnchor(
            semanticID: selected.1,
            renderedID: selected.0,
            layoutEpoch: layoutEpoch,
            viewportOffsetY: selected.2.minY
        )
    }

    func scrollPositionChanged(isPositionedByUser: Bool) {
        if isPositionedByUser {
            bindingIsReleased = false
            directTailReturnArmed = true
            interruptCatchUpIfAway()
            cancelAutomaticWorkForUserInteraction()
            pendingNativeUserGeometry = true
            if pendingUnattributedOlderMovement {
                pendingUnattributedOlderMovement = false
                directTailReturnArmed = false
                commitScrollAway()
                pendingNativeUserGeometry = false
            }

            // SwiftUI can publish final bottom geometry before it marks the
            // ScrollPosition as user-owned. For an already-detached reader,
            // that callback pair is direct proof of a manual return to latest.
            if userScrolledAway,
               geometry.isAtCatchUpBoundary,
               boundaryCameFromViewportWithoutTailMovement {
                directTailReturnArmed = isUserInteracting || isUserDrivenSettling
                pendingNativeUserGeometry = false
                isNativeUserOwned = false
                hadUserInteraction = false
                return
            }
            if userScrolledAway,
               geometry.isAtCatchUpBoundary,
               !boundaryCameFromViewportWithoutTailMovement {
                directTailReturnArmed = false
                pendingNativeUserGeometry = false
                isNativeUserOwned = false
                admitTailBoundary(directlyOwned: true)
                return
            }
        }
        isNativeUserOwned = isPositionedByUser
    }

    /// Arms pinned following for the next measured keyboard/composer viewport
    /// change. It emits no immediate write, and detached readers are inert.
    func composerViewportTransitionBegan() {
        guard !userScrolledAway, catchUpPhase == .none, !isPrependingHistory else { return }
        let hasFreshNativeAuthority = isUserInteracting || pendingNativeUserGeometry
            || isUserDrivenSettling || directTailReturnArmed
        if geometry.isAtCatchUpBoundary && !hasFreshNativeAuthority {
            // Persistent native binding ownership is not fresh navigation intent.
            // A live gesture/callback sequence must retain every directional fact.
            isNativeUserOwned = false
        }
        pendingGrowthFollow = true
        pendingContinuousGrowthFollow = true
        scheduleTailFollow()
    }

    func scrollPhaseChanged(from oldPhase: ScrollPhase, to newPhase: ScrollPhase, finalGeometry: ChatTranscriptGeometry?) {
        if let finalGeometry { geometry = finalGeometry }
        let wasInteracting = isUserInteracting
        let wasSettling = isUserDrivenSettling
        isUserInteracting = Self.isDirectUserPhase(newPhase)
        isScrollAnimating = newPhase == .animating
        isUserDrivenSettling = isScrollAnimating && (wasSettling || Self.isDirectUserPhase(oldPhase))

        if isUserInteracting && !wasInteracting {
            directTailReturnArmed = true
            interruptCatchUpIfAway()
            cancelAutomaticWorkForUserInteraction()
            hadUserInteraction = true
            userInteractionStartOffsetY = finalGeometry?.offsetY
            userInteractionStartDistanceFromBottom = finalGeometry?.distanceFromBottom
        }
        guard newPhase == .idle else { return }

        let movedOlder: Bool
        let movedTowardLatest: Bool
        if let startY = userInteractionStartOffsetY,
           let startDistance = userInteractionStartDistanceFromBottom,
           let finalGeometry {
            movedOlder = finalGeometry.offsetY < startY - 1
                && finalGeometry.distanceFromBottom > startDistance + 1
            movedTowardLatest = finalGeometry.offsetY > startY + 1
                && finalGeometry.distanceFromBottom < startDistance - 1
        } else {
            movedOlder = false
            movedTowardLatest = false
        }
        userInteractionStartOffsetY = nil
        userInteractionStartDistanceFromBottom = nil

        if finalGeometry?.isAtCatchUpBoundary == true {
            let directlyOwnedReturn = directTailReturnArmed && movedTowardLatest
            admitTailBoundary(directlyOwned: directlyOwnedReturn)
            if userScrolledAway {
                // A rejected viewport-only boundary consumes all transient
                // native/direct authority. Later streaming geometry must not
                // reinterpret that keyboard interaction as a tail return.
                isNativeUserOwned = false
                pendingNativeUserGeometry = false
                hadUserInteraction = false
                isUserDrivenSettling = false
            }
        } else if (wasInteracting || wasSettling) && movedOlder {
            commitScrollAway()
        } else if !userScrolledAway && catchUpPhase == .none {
            isNativeUserOwned = false
            pendingNativeUserGeometry = false
            isUserDrivenSettling = false
            if pendingGrowthFollow { scheduleTailFollow() }
        }
        directTailReturnArmed = false
    }

    func geometryChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        geometry = current
        geometryRevision &+= 1
        evaluateLayoutMutationIfReady()
        evaluatePrependMeasurementIfReady()
        evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        if openingTailSettlementPending { return }
        let grew = current.contentHeight > previous.contentHeight + 0.5
        let movedOlder = previous.isValid
            && current.offsetY < previous.offsetY - 1
            && current.distanceFromBottom > previous.distanceFromBottom + 1
        let movedTowardLatest = previous.isValid
            && current.offsetY > previous.offsetY + 1
            && current.distanceFromBottom < previous.distanceFromBottom - 1
        let preservesRejectedViewportAuthority = userScrolledAway
            && boundaryCameFromViewportWithoutTailMovement
            && !movedTowardLatest
        if !preservesRejectedViewportAuthority {
            boundaryCameFromViewportWithoutTailMovement = false
        }
        // Persistent native binding ownership is not fresh navigation intent.
        // Only the current direct phase/callback admission may release detachment.
        let attributed = !preservesRejectedViewportAuthority
            && (isUserInteracting || hadUserInteraction
                || pendingNativeUserGeometry || isUserDrivenSettling || directTailReturnArmed)

        if current.isAtCatchUpBoundary {
            admitTailBoundary(directlyOwned: attributed)
            if !preservesRejectedViewportAuthority || !isUserInteracting {
                directTailReturnArmed = false
            }
        } else {
            if isAtBottom != current.isAtBottom { isAtBottom = current.isAtBottom }
            if movedOlder && !attributed { pendingUnattributedOlderMovement = true }
            if attributed && !isUserInteracting && !isUserDrivenSettling && movedOlder {
                commitScrollAway()
            }
        }
        pendingNativeUserGeometry = false
        if !isUserInteracting { hadUserInteraction = false }

        guard grew, previous.isValid, !userScrolledAway,
              catchUpPhase == .none, !isPrependingHistory else { return }
        pendingGrowthFollow = true
        pendingContinuousGrowthFollow = true
        scheduleTailFollow()
    }

    func viewportChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        geometry = current
        geometryRevision &+= 1
        evaluateLayoutMutationIfReady()
        evaluatePrependMeasurementIfReady()
        evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        if openingTailSettlementPending { return }
        guard current.hasViewportChange(from: previous) else { return }
        pendingUnattributedOlderMovement = false
        if userScrolledAway {
            let movedTowardLatest = (
                current.offsetY > previous.offsetY + 1
                    && current.distanceFromBottom < previous.distanceFromBottom - 1
            ) || (
                userInteractionStartOffsetY.map { current.offsetY > $0 + 1 } == true
                    && userInteractionStartDistanceFromBottom.map {
                        current.distanceFromBottom < $0 - 1
                    } == true
            )
            boundaryCameFromViewportWithoutTailMovement = current.isAtCatchUpBoundary
                && !movedTowardLatest
            let directlyOwned = isUserInteracting || isUserDrivenSettling
                || pendingNativeUserGeometry || directTailReturnArmed
            if current.isAtCatchUpBoundary, directlyOwned, movedTowardLatest {
                admitTailBoundary(directlyOwned: true)
                directTailReturnArmed = false
                return
            }
            // Preserve authority throughout an active direct gesture so an
            // intermediate keyboard viewport frame cannot erase a later
            // coalesced return-to-tail settlement. Outside that gesture,
            // consume stale one-shot authority so resize alone cannot re-pin.
            if !isUserInteracting && !isUserDrivenSettling {
                directTailReturnArmed = false
            }
            isAtBottom = false
            return
        }
        if current.isAtCatchUpBoundary {
            admitTailBoundary(directlyOwned: false)
            return
        }
        isAtBottom = false
        guard catchUpPhase == .none else { return }
        pendingGrowthFollow = true
        pendingContinuousGrowthFollow = true
        scheduleTailFollow()
    }

    /// Positions the exact installed physical tail before the transcript is
    /// revealed. Submission of a `ScrollPosition` write is not completion: the
    /// continuation resumes only after fresh semantic and native geometry prove
    /// that the target intersects a plausible bottom viewport.
    func positionOpeningTail(targetRenderedID: String?) async -> Bool {
        guard let targetRenderedID else { return true }
        clearOpeningTailSettlement(positioningSucceeded: false)
        sequence &+= 1
        let token = sequence
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
                    positioningSucceeded: false
                )
            }
        }
    }

    /// Test and preview seam for callback-order characterization.
    func requestOpeningTail(targetRenderedID: String?) {
        clearOpeningTailSettlement(positioningSucceeded: false)
        guard let targetRenderedID else { return }
        sequence &+= 1
        beginOpeningTailSettlement(
            token: sequence,
            targetRenderedID: targetRenderedID,
            continuation: nil
        )
    }

    /// The first visible frame starts only after physical positioning succeeds.
    /// Keep the edge binding through the fade/slide transaction, then release it
    /// after animation completion and two unchanged display-frame barriers.
    func openingRevealCompleted() {
        guard openingTailSettlementPending, openingTailPositioned else { return }
        openingTailRevealCompleted = true
        scheduleOpeningTailFrame()
    }

    func waitForOpeningTailSettlement() async {
        guard openingTailSettlementPending, let token = openingTailToken else { return }
        let waiterID = nextOpeningTailFinalWaiterID
        nextOpeningTailFinalWaiterID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if openingTailSettlementPending, openingTailToken == token {
                    openingTailFinalWaiters.append(.init(
                        id: waiterID,
                        token: token,
                        continuation: continuation
                    ))
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeOpeningTailFinalWaiter(id: waiterID, token: token)
            }
        }
    }

    private func beginOpeningTailSettlement(
        token: Int,
        targetRenderedID: String,
        continuation: CheckedContinuation<Bool, Never>?
    ) {
        openingTailSettlementPending = true
        openingTailToken = token
        openingTailTargetRenderedID = targetRenderedID
        openingTailTargetSample = semanticFrames[targetRenderedID]
        openingTailPresentation = presentation
        openingTailCommandAttemptCount = 0
        openingTailContinuation = continuation
        evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        if openingTailSettlementPending, !openingTailPositioned {
            scheduleOpeningTailFrame()
        }
    }

    func requestCatchUp(reduceMotion: Bool) {
        cancelLayoutMutation()
        cancelCatchUp(restoringDetached: false)
        if isPrependingHistory {
            prependInterrupted = true
            if prependRenderedAnchorID != nil { finishPrepend(token: prependToken, result: .discarded) }
        }
        cancelAutomaticTasks()
        catchUpUnreadBeforeJump = hasUnreadContent
        catchUpPhase = .final
        userScrolledAway = false
        isAtBottom = false

        if reduceMotion {
            publishCatchUpTail(animation: .disabled)
            return
        }
        let threshold = max(320, geometry.containerHeight * 0.8)
        guard geometry.distanceFromBottom > threshold else {
            publishCatchUpTail(animation: .smooth(duration: 0.30))
            return
        }
        let reveal = min(140, max(80, geometry.containerHeight * 0.18))
        let bottomOffset = geometry.contentHeight + geometry.bottomInset - geometry.containerHeight
        catchUpPhase = .staged
        publish(.offsetY(max(0, bottomOffset - reveal)), animation: .disabled, origin: .catchUp)
        catchUpCommandToken = command?.token
    }

    /// Captures the currently visible semantic locus before an ordinary projection
    /// install. Repeated desired sources coalesce around the first captured locus;
    /// the exact installed generation retargets it after publication.
    func transcriptProjectionWillChange(from installed: InstalledChatTranscript?) {
        guard !isPrependingHistory, let installed else { return }
        if !layoutMutationPendingInstall,
           layoutMutationExpectedLayoutEpoch == nil,
           layoutMutationCorrectionCommandToken == nil {
            layoutMutationWasDetached = userScrolledAway
            layoutMutationAnchor = userScrolledAway ? semanticAnchor(in: installed.timeline) : nil
            layoutMutationCorrectionCount = 0
        }
        // Geometry may settle before the frame-gated projection waiter resumes.
        // The pre-submission revision is therefore the mutation boundary; using
        // the later installed-layout epoch could wait forever for another callback.
        layoutMutationRequiredGeometryRevision = geometryRevision
        layoutMutationPendingInstall = true
    }

    /// An actual installed transition retains a pending entrance entitlement only
    /// while that exact rendered row remains displayed, then starts one owned
    /// layout settlement for the installed generation.
    func installedTranscriptChanged(_ installed: InstalledChatTranscript?) {
        guard let installed else {
            cancelDiscreteFollowOwnership()
            // Identity-changing submissions synchronously clear the installed
            // value before publishing their replacement. Preserve the anchor
            // transaction already captured for that admitted work.
            if !layoutMutationPendingInstall {
                finishLayoutMutation(releasesCorrectedBinding: true)
            }
            return
        }
        if !discreteFollowRenderedIDs.isEmpty {
            discreteFollowRenderedIDOrder.removeAll {
                !discreteFollowRenderedIDs.contains($0) || !installed.containsDisplayedID($0)
            }
            discreteFollowRenderedIDs = Set(discreteFollowRenderedIDOrder)
            if discreteFollowRenderedIDs.isEmpty { cancelDiscreteFollowOwnership() }
        }

        guard layoutMutationPendingInstall else { return }
        layoutMutationPendingInstall = false
        if layoutMutationWasDetached {
            guard userScrolledAway, !isUserInteracting,
                  !pendingNativeUserGeometry, !isUserDrivenSettling,
                  let anchor = layoutMutationAnchor,
                  let renderedID = installed.timeline.renderedIDBySemanticID[anchor.semanticID] else {
                finishLayoutMutation(releasesCorrectedBinding: true)
                return
            }
            retireLayoutMutationCorrectionCommand()
            releaseLayoutMutationBindingIfNeeded()
            let installedLayout = beginInstalledLayoutEpoch()
            layoutMutationRenderedAnchorID = renderedID
            layoutMutationExpectedLayoutEpoch = installedLayout.value
            layoutMutationRequiredSampleRevision = installedLayout.firstValidSampleRevision
            layoutMutationReadyForMeasurement = true
            layoutMutationCorrectionCount = 0
            evaluateLayoutMutationIfReady()
        } else {
            guard canAutomaticallyFollow else {
                finishLayoutMutation()
                return
            }
            pendingInstalledTailSettlement = true
            pendingGrowthFollow = true
            pendingContinuousGrowthFollow = true
            finishLayoutMutation(keepingTailSettlement: true)
            scheduleTailFollow()
        }
    }

    /// A geometry-admitted visible row insertion requests one coalesced,
    /// nonanimated tail settlement. Continuous streaming growth uses the same
    /// viewport policy and never creates a competing animation.
    func discreteContentInserted(renderedID: String) {
        guard canAutomaticallyFollow else { return }
        if discreteFollowRenderedIDs.insert(renderedID).inserted {
            discreteFollowRenderedIDOrder.append(renderedID)
            let maximum = ChatTranscriptPageRequest.maximumItemCount
            if discreteFollowRenderedIDOrder.count > maximum {
                let excess = discreteFollowRenderedIDOrder.count - maximum
                let retired = Array(discreteFollowRenderedIDOrder.prefix(excess))
                discreteFollowRenderedIDOrder.removeFirst(excess)
                discreteFollowRenderedIDs.subtract(retired)
            }
        }
        pendingGrowthFollow = true
        scheduleTailFollow()
    }

    func semanticResponseArrived() {
        if shouldTrackUnreadResponse { hasUnreadContent = true }
    }

    @discardableResult
    func beginPrepend(
        anchor: ChatSemanticAnchor?,
        load: @escaping @MainActor @Sendable () async -> ChatPrependPage?,
        completion: @escaping @MainActor (PerformanceResult) -> Void
    ) -> Bool {
        guard !isPrependingHistory, catchUpPhase == .none,
              !openingTailSettlementPending, command == nil,
              let anchor, anchor.layoutEpoch == layoutEpoch,
              let admittedSample = semanticFrames[anchor.renderedID],
              admittedSample.layoutEpoch == anchor.layoutEpoch,
              abs(admittedSample.frame.minY - anchor.viewportOffsetY) <= 0.5,
              admittedSample.frame.maxY > 0,
              admittedSample.frame.minY < geometry.containerHeight else {
            completion(.discarded)
            return false
        }
        cancelLayoutMutation()
        sequence &+= 1
        let token = sequence
        let admittedPresentation = presentation
        isPrependingHistory = true
        prependToken = token
        prependWasScrolledAway = userScrolledAway
        prependInterrupted = false
        prependAnchor = anchor
        prependRenderedAnchorID = nil
        prependExpectedLayoutEpoch = nil
        prependReadyForMeasurement = false
        prependRequiredSampleRevision = semanticFrameRevision
        prependRequiredGeometryRevision = geometryRevision
        prependCorrectionCount = 0
        prependCorrectionCommandToken = nil
        prependAppliedOffset = false
        prependCompletion = completion
        maximumPrependSemanticExcursion = 0
        pendingGrowthFollow = false
        cancelAutomaticTasks()

        prependTask = Task { [weak self] in
            let page = await load()
            guard let self, self.prependToken == token, self.presentation == admittedPresentation else { return }
            self.prependTask = nil
            guard let page,
                  page.installedLayout.value == self.layoutEpoch,
                  page.installedLayout.value != anchor.layoutEpoch else {
                self.finishPrepend(token: token, result: .discarded)
                return
            }
            guard !self.prependInterrupted else {
                self.finishPrepend(token: token, result: .discarded)
                return
            }
            self.prependRenderedAnchorID = page.renderedAnchorID
            self.prependExpectedLayoutEpoch = page.installedLayout.value
            // The epoch boundary, not load-continuation timing, is authority.
            // A valid sample may already have arrived after publication.
            self.prependRequiredSampleRevision = page.installedLayout.firstValidSampleRevision
            // Keep the pre-load geometry boundary captured by beginPrepend.
            // Installation can settle geometry before this continuation resumes.
            self.prependReadyForMeasurement = true
            self.evaluatePrependMeasurementIfReady()
            #if HOSTED_TEST
            self.resumeHostedPrependSampleWaiters()
            #endif
        }
        return true
    }

    func commandApplied(_ applied: ChatScrollCommand) {
        guard command?.token == applied.token, applied.presentation == presentation else { return }
        command = nil
        switch applied.destination {
        case .resetToBottom:
            bindingIsReleased = false
        case .releaseBinding:
            bindingIsReleased = true
        case .tail, .openingTail, .offsetY:
            bindingIsReleased = false
        }

        if openingTailCommandToken == applied.token {
            // Submission is not physical completion. Retain the token until a
            // later display-frame/evidence pair proves settlement, preventing
            // multiple SwiftUI binding writes in one render transaction.
            scheduleOpeningTailFrame()
        }

        if catchUpCommandToken == applied.token {
            catchUpCommandToken = nil
            if catchUpPhase == .staged {
                let admittedPresentation = presentation
                catchUpTask = Task { [weak self, frameScheduler] in
                    do {
                        try await frameScheduler.nextFrame()
                        try Task.checkCancellation()
                    } catch {
                        guard let self, self.presentation == admittedPresentation else { return }
                        self.cancelCatchUp(restoringDetached: true)
                        return
                    }
                    guard let self, self.presentation == admittedPresentation,
                          self.catchUpPhase == .staged,
                          !self.isUserInteracting else { return }
                    self.catchUpTask = nil
                    self.catchUpPhase = .final
                    self.publishCatchUpTail(animation: .smooth(duration: 0.30))
                }
            } else if catchUpPhase == .final {
                catchUpPhase = .settling
            }
        }

        if layoutMutationCorrectionCommandToken == applied.token {
            layoutMutationCorrectionCommandToken = nil
            layoutMutationAppliedOffset = true
            layoutMutationRequiredSampleRevision = semanticFrameRevision
            layoutMutationRequiredGeometryRevision = geometryRevision
            layoutMutationReadyForMeasurement = true
        }

        if prependCorrectionCommandToken == applied.token {
            prependCorrectionCommandToken = nil
            prependAppliedOffset = true
            prependRequiredSampleRevision = semanticFrameRevision
            prependRequiredGeometryRevision = geometryRevision
            prependReadyForMeasurement = true
        }

        evaluateLayoutMutationIfReady()
        evaluatePrependMeasurementIfReady()
    }

    func cancel() {
        cancelAllOwnedWork(result: .cancelled)
        clearCommand()
    }

    private func admitTailBoundary(directlyOwned: Bool) {
        if catchUpPhase == .settling {
            finishCatchUpPinned()
            requestBindingReleaseIfSettled()
            return
        }
        if userScrolledAway && !directlyOwned {
            isAtBottom = false
            return
        }
        if userScrolledAway && directlyOwned { userScrolledAway = false }
        releaseAtBottom()
        requestBindingReleaseIfSettled()
    }

    private func interruptCatchUpIfAway() {
        guard catchUpPhase != .none, !geometry.isAtCatchUpBoundary else { return }
        cancelCatchUp(restoringDetached: true)
    }

    private func publishCatchUpTail(animation: ChatScrollAnimation) {
        publish(.tail, animation: animation, origin: .catchUp)
        catchUpCommandToken = command?.token
    }

    private func finishCatchUpPinned() {
        catchUpTask?.cancel()
        catchUpTask = nil
        catchUpPhase = .none
        catchUpCommandToken = nil
        catchUpUnreadBeforeJump = false
        releaseAtBottom()
    }

    private func cancelCatchUp(restoringDetached: Bool) {
        catchUpTask?.cancel()
        catchUpTask = nil
        let ownedToken = catchUpCommandToken
        catchUpCommandToken = nil
        let wasActive = catchUpPhase != .none
        catchUpPhase = .none
        if let ownedToken, command?.token == ownedToken { clearCommand() }
        if restoringDetached && wasActive {
            userScrolledAway = true
            hasUnreadContent = catchUpUnreadBeforeJump || hasUnreadContent
            isAtBottom = false
        }
        catchUpUnreadBeforeJump = false
    }

    private func evaluateLayoutMutationIfReady() {
        guard layoutMutationReadyForMeasurement,
              command == nil, layoutMutationCorrectionCommandToken == nil,
              layoutMutationWasDetached, userScrolledAway,
              !isUserInteracting, !pendingNativeUserGeometry, !isUserDrivenSettling,
              let anchor = layoutMutationAnchor,
              let renderedID = layoutMutationRenderedAnchorID,
              let expectedEpoch = layoutMutationExpectedLayoutEpoch,
              expectedEpoch == layoutEpoch,
              let sample = semanticFrames[renderedID],
              sample.layoutEpoch == expectedEpoch,
              sample.revision > layoutMutationRequiredSampleRevision,
              geometryRevision > layoutMutationRequiredGeometryRevision else { return }
        layoutMutationReadyForMeasurement = false
        let residual = sample.frame.minY - anchor.viewportOffsetY
        if abs(residual) <= 1 {
            finishLayoutMutation(releasesCorrectedBinding: true)
            return
        }
        guard layoutMutationCorrectionCount < 2 else {
            // The bounded transaction failed to converge, but this decision is
            // still paired with fresh semantic and geometry evidence.
            finishLayoutMutation(releasesCorrectedBinding: true)
            return
        }
        layoutMutationCorrectionCount &+= 1
        let requested = Self.prependCorrectionOffset(
            currentOffsetY: geometry.offsetY,
            capturedViewportOffsetY: anchor.viewportOffsetY,
            installedFrameMinY: sample.frame.minY
        )
        publish(.offsetY(requested), animation: .disabled, origin: .layout)
        layoutMutationCorrectionCommandToken = command?.token
    }

    private func evaluatePrependMeasurementIfReady() {
        guard prependReadyForMeasurement,
              command == nil, prependCorrectionCommandToken == nil,
              let token = prependToken, !prependInterrupted,
              let anchor = prependAnchor,
              let renderedID = prependRenderedAnchorID,
              let expectedEpoch = prependExpectedLayoutEpoch,
              expectedEpoch == layoutEpoch,
              let sample = semanticFrames[renderedID],
              sample.layoutEpoch == expectedEpoch,
              sample.revision > prependRequiredSampleRevision,
              geometryRevision > prependRequiredGeometryRevision else { return }
        prependReadyForMeasurement = false
        let residual = sample.frame.minY - anchor.viewportOffsetY
        maximumPrependSemanticExcursion = max(maximumPrependSemanticExcursion, abs(residual))
        if abs(residual) <= 1 {
            finishPrepend(
                token: token,
                result: .success,
                releasesCorrectedBinding: prependCorrectionCount > 0
            )
            return
        }
        guard prependCorrectionCount < 2 else {
            finishPrepend(
                token: token,
                result: .failure,
                releasesCorrectedBinding: true
            )
            return
        }
        prependCorrectionCount &+= 1
        let requested = Self.prependCorrectionOffset(
            currentOffsetY: geometry.offsetY,
            capturedViewportOffsetY: anchor.viewportOffsetY,
            installedFrameMinY: sample.frame.minY
        )
        publish(.offsetY(requested), animation: .disabled, origin: .prepend)
        prependCorrectionCommandToken = command?.token
    }

    private func recordPrependExcursionIfOwned(renderedID: String, layoutEpoch: Int, frame: CGRect) {
        guard renderedID == prependRenderedAnchorID,
              layoutEpoch == prependExpectedLayoutEpoch,
              let anchor = prependAnchor else { return }
        maximumPrependSemanticExcursion = max(
            maximumPrependSemanticExcursion,
            abs(frame.minY - anchor.viewportOffsetY)
        )
    }

    private func scheduleTailFollow() {
        guard pendingGrowthFollow, canAutomaticallyFollow,
              (pendingInstalledTailSettlement
                || !discreteFollowRenderedIDs.isEmpty
                || geometry.distanceFromBottom > ChatTranscriptGeometry.catchUpDistance),
              followFrameTask == nil else { return }
        let admittedPresentation = presentation
        followFrameTask = Task { [weak self, frameScheduler] in
            do {
                try await frameScheduler.nextFrame()
                try Task.checkCancellation()
            } catch { return }
            guard let self else { return }
            #if HOSTED_TEST
            defer { self.completeHostedFollowDecision() }
            #endif
            self.followFrameTask = nil
            guard self.presentation == admittedPresentation,
                  self.pendingGrowthFollow, self.canAutomaticallyFollow else { return }
            self.pendingGrowthFollow = false
            self.pendingContinuousGrowthFollow = false
            self.pendingInstalledTailSettlement = false
            self.clearDiscreteFollowIDs()
            if self.geometry.distanceFromBottom > ChatTranscriptGeometry.catchUpDistance {
                self.publish(.tail, animation: .disabled, origin: .automaticFollow)
            }
        }
    }

    private func requestBindingReleaseIfSettled() {
        guard !bindingIsReleased, command == nil,
              followFrameTask == nil, catchUpTask == nil,
              catchUpPhase == .none, !isPrependingHistory,
              !openingTailSettlementPending,
              !isUserInteracting, !isScrollAnimating,
              geometry.isAtCatchUpBoundary else { return }
        publish(.releaseBinding, animation: .disabled, origin: .binding)
    }

    private func publish(
        _ destination: ChatScrollCommand.Destination,
        animation: ChatScrollAnimation,
        origin: ChatScrollCommand.Origin
    ) {
        sequence &+= 1
        command = .init(
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
        guard command != nil else { return }
        command = nil
        commandRevision &+= 1
    }

    private func cancelAutomaticWorkForUserInteraction() {
        clearOpeningTailSettlement()
        cancelLayoutMutation()
        cancelAutomaticTasks()
        if isPrependingHistory {
            prependInterrupted = true
            let token = prependToken
            prependTask?.cancel()
            finishPrepend(token: token, result: .discarded)
        }
        clearCommand()
    }

    private func cancelAutomaticTasks() {
        followFrameTask?.cancel()
        followFrameTask = nil
        pendingGrowthFollow = false
        pendingContinuousGrowthFollow = false
        pendingInstalledTailSettlement = false
        clearDiscreteFollowIDs()
    }

    private func cancelDiscreteFollowOwnership() {
        clearDiscreteFollowIDs()
        guard !pendingContinuousGrowthFollow else { return }
        followFrameTask?.cancel()
        followFrameTask = nil
        pendingGrowthFollow = false
    }

    private func clearDiscreteFollowIDs() {
        discreteFollowRenderedIDs.removeAll(keepingCapacity: true)
        discreteFollowRenderedIDOrder.removeAll(keepingCapacity: true)
    }

    private func retireLayoutMutationCorrectionCommand() {
        guard let token = layoutMutationCorrectionCommandToken else { return }
        if command?.token == token { clearCommand() }
        layoutMutationCorrectionCommandToken = nil
    }

    private func releaseLayoutMutationBindingIfNeeded() {
        guard layoutMutationAppliedOffset else { return }
        layoutMutationAppliedOffset = false
        if command == nil {
            publish(.releaseBinding, animation: .disabled, origin: .binding)
        }
    }

    private func finishLayoutMutation(
        keepingTailSettlement: Bool = false,
        releasesCorrectedBinding: Bool = false
    ) {
        let shouldReleaseBinding = releasesCorrectedBinding
            && layoutMutationAppliedOffset
            && layoutMutationCorrectionCommandToken == nil
            && userScrolledAway && !isUserInteracting
            && !pendingNativeUserGeometry && !isUserDrivenSettling
        retireLayoutMutationCorrectionCommand()
        layoutMutationAnchor = nil
        layoutMutationWasDetached = false
        layoutMutationPendingInstall = false
        layoutMutationRenderedAnchorID = nil
        layoutMutationExpectedLayoutEpoch = nil
        layoutMutationRequiredSampleRevision = semanticFrameRevision
        layoutMutationRequiredGeometryRevision = geometryRevision
        layoutMutationReadyForMeasurement = false
        layoutMutationCorrectionCount = 0
        layoutMutationAppliedOffset = false
        if !keepingTailSettlement { pendingInstalledTailSettlement = false }
        if shouldReleaseBinding, command == nil {
            publish(.releaseBinding, animation: .disabled, origin: .binding)
        }
    }

    private func cancelLayoutMutation() {
        finishLayoutMutation(releasesCorrectedBinding: false)
    }

    private func cancelAllOwnedWork(result: PerformanceResult) {
        clearOpeningTailSettlement()
        cancelLayoutMutation()
        cancelAutomaticTasks()
        cancelCatchUp(restoringDetached: false)
        prependTask?.cancel()
        prependTask = nil
        if isPrependingHistory { prependCompletion?(result) }
        prependCompletion = nil
        prependToken = nil
        prependAnchor = nil
        prependRenderedAnchorID = nil
        prependExpectedLayoutEpoch = nil
        prependReadyForMeasurement = false
        prependRequiredSampleRevision = semanticFrameRevision
        prependRequiredGeometryRevision = geometryRevision
        prependCorrectionCommandToken = nil
        prependAppliedOffset = false
        isPrependingHistory = false
        #if HOSTED_TEST
        cancelHostedPrependSampleWaiters()
        #endif
    }

    private func finishPrepend(
        token: Int?,
        result: PerformanceResult,
        releasesCorrectedBinding: Bool = false
    ) {
        guard token == prependToken else { return }
        let shouldReleaseBinding = releasesCorrectedBinding
            && prependAppliedOffset
            && prependCorrectionCommandToken == nil
            && !prependInterrupted && !isUserInteracting
            && !pendingNativeUserGeometry && !isUserDrivenSettling
        prependTask = nil
        prependToken = nil
        prependAnchor = nil
        prependRenderedAnchorID = nil
        prependExpectedLayoutEpoch = nil
        prependReadyForMeasurement = false
        prependRequiredSampleRevision = semanticFrameRevision
        prependRequiredGeometryRevision = geometryRevision
        prependCorrectionCommandToken = nil
        prependAppliedOffset = false
        isPrependingHistory = false
        #if HOSTED_TEST
        cancelHostedPrependSampleWaiters()
        #endif
        if !prependInterrupted {
            userScrolledAway = prependWasScrolledAway
            if prependWasScrolledAway { isAtBottom = false }
        }
        let completion = prependCompletion
        prependCompletion = nil
        completion?(result)
        if shouldReleaseBinding, command == nil {
            publish(.releaseBinding, animation: .disabled, origin: .binding)
        } else if pendingGrowthFollow {
            scheduleTailFollow()
        }
    }

    private func evaluateOpeningTailIfPossible(
        allowsUnrealizedTailCommand: Bool,
        schedulesPositionedFrame: Bool = true
    ) {
        guard openingTailSettlementPending,
              openingTailPresentation == presentation,
              let targetRenderedID = openingTailTargetRenderedID else { return }

        let targetSample = openingTailTargetSample
        let hasCurrentTarget = targetSample?.layoutEpoch == layoutEpoch
        let targetIsVisible = hasCurrentTarget
            && targetSample!.frame.maxY > 0
            && targetSample!.frame.minY < geometry.containerHeight
        let physicallyPositioned = geometry.isPlausibleOpeningViewport
            && geometry.isAtCatchUpBoundary
            && targetIsVisible

        if physicallyPositioned {
            openingTailCommandToken = nil
            openingTailCommandSemanticRevision = nil
            openingTailCommandGeometryRevision = nil
            if !openingTailPositioned {
                openingTailPositioned = true
                let continuation = openingTailContinuation
                openingTailContinuation = nil
                continuation?.resume(returning: true)
            }
            if openingTailRevealCompleted, schedulesPositionedFrame {
                scheduleOpeningTailFrame()
            }
            return
        }

        if let openingCommandToken = openingTailCommandToken {
            let hasFreshEvidence = semanticFrameRevision > (openingTailCommandSemanticRevision ?? semanticFrameRevision)
                || geometryRevision > (openingTailCommandGeometryRevision ?? geometryRevision)
            if hasFreshEvidence, command?.token != openingCommandToken {
                scheduleOpeningTailFrame()
            }
            return
        }

        guard geometry.isValid,
              canAutomaticallyFollow, command == nil,
              hasCurrentTarget || allowsUnrealizedTailCommand else { return }
        guard let targetRenderedID = openingTailTargetRenderedID else { return }
        publish(.openingTail(targetRenderedID), animation: .disabled, origin: .presentation)
        openingTailCommandToken = command?.token
        openingTailCommandSemanticRevision = semanticFrameRevision
        openingTailCommandGeometryRevision = geometryRevision
        openingTailCommandAttemptCount &+= 1
    }

    private func scheduleOpeningTailFrame() {
        guard openingTailSettlementPending,
              openingTailPresentation == presentation else { return }
        openingTailFrameTask?.cancel()
        openingTailFrameTaskGeneration &+= 1
        let taskGeneration = openingTailFrameTaskGeneration
        let admittedPresentation = presentation
        let admittedSemanticRevision = semanticFrameRevision
        let admittedGeometryRevision = geometryRevision
        openingTailFrameTask = Task { [weak self, frameScheduler] in
            do {
                try await frameScheduler.nextFrame()
                try Task.checkCancellation()
            } catch {
                guard let self,
                      self.presentation == admittedPresentation,
                      self.openingTailFrameTaskGeneration == taskGeneration else { return }
                // A display-frame helper can be cancelled independently of the
                // owning presentation task. Physical semantic/geometry callbacks
                // remain authoritative and may still complete positioning.
                self.openingTailFrameTask = nil
                return
            }
            guard let self,
                  self.presentation == admittedPresentation,
                  self.openingTailSettlementPending,
                  self.openingTailFrameTaskGeneration == taskGeneration else { return }
            self.openingTailFrameTask = nil
            let revisionsAreStable = self.semanticFrameRevision == admittedSemanticRevision
                && self.geometryRevision == admittedGeometryRevision
            let hasFreshCommandEvidence = self.semanticFrameRevision
                > (self.openingTailCommandSemanticRevision ?? self.semanticFrameRevision)
                || self.geometryRevision
                > (self.openingTailCommandGeometryRevision ?? self.geometryRevision)
            if !self.openingTailPositioned,
               let openingCommandToken = self.openingTailCommandToken,
               self.command?.token != openingCommandToken,
               hasFreshCommandEvidence || self.openingTailCommandAttemptCount < 2 {
                // Permit one bounded second exact-ID submission if SwiftUI
                // consumed the first against a provisional lazy layout. Further
                // writes require new semantic or geometry evidence.
                self.openingTailCommandToken = nil
                self.openingTailCommandSemanticRevision = nil
                self.openingTailCommandGeometryRevision = nil
            }
            self.evaluateOpeningTailIfPossible(
                allowsUnrealizedTailCommand: true,
                schedulesPositionedFrame: false
            )
            guard self.openingTailSettlementPending,
                  self.openingTailFrameTaskGeneration == taskGeneration else { return }
            if self.openingTailPositioned,
               self.openingTailRevealCompleted,
               revisionsAreStable,
               self.openingTailViewportIsPhysicallySettled {
                if self.openingTailStableSemanticRevision == admittedSemanticRevision,
                   self.openingTailStableGeometryRevision == admittedGeometryRevision {
                    self.openingTailStableFrameCount &+= 1
                } else {
                    self.openingTailStableSemanticRevision = admittedSemanticRevision
                    self.openingTailStableGeometryRevision = admittedGeometryRevision
                    self.openingTailStableFrameCount = 1
                }
                if self.openingTailStableFrameCount >= 2 {
                    self.finishOpeningTailSettlement()
                } else {
                    self.scheduleOpeningTailFrame()
                }
            } else if self.openingTailPositioned && self.openingTailRevealCompleted {
                self.openingTailStableFrameCount = 0
                self.openingTailStableSemanticRevision = nil
                self.openingTailStableGeometryRevision = nil
                self.scheduleOpeningTailFrame()
            }
        }
    }

    private var openingTailViewportIsPhysicallySettled: Bool {
        guard openingTailTargetRenderedID != nil,
              let targetSample = openingTailTargetSample,
              targetSample.layoutEpoch == layoutEpoch else { return false }
        return geometry.isPlausibleOpeningViewport
            && geometry.isAtCatchUpBoundary
            && targetSample.frame.maxY > 0
            && targetSample.frame.minY < geometry.containerHeight
    }

    private func finishOpeningTailSettlement() {
        let token = openingTailToken
        openingTailFrameTaskGeneration &+= 1
        openingTailFrameTask?.cancel()
        openingTailFrameTask = nil
        openingTailSettlementPending = false
        openingTailToken = nil
        openingTailTargetRenderedID = nil
        openingTailTargetSample = nil
        openingTailPresentation = nil
        openingTailCommandToken = nil
        openingTailCommandSemanticRevision = nil
        openingTailCommandGeometryRevision = nil
        openingTailCommandAttemptCount = 0
        openingTailPositioned = false
        openingTailRevealCompleted = false
        openingTailStableFrameCount = 0
        openingTailStableSemanticRevision = nil
        openingTailStableGeometryRevision = nil
        let continuation = openingTailContinuation
        openingTailContinuation = nil
        continuation?.resume(returning: true)
        if let token { resumeOpeningTailFinalWaiters(token: token) }
        releaseAtBottom()
        requestBindingReleaseIfSettled()
    }

    private func clearOpeningTailSettlement(
        ifToken expectedToken: Int? = nil,
        positioningSucceeded: Bool = false
    ) {
        if let expectedToken, openingTailToken != expectedToken { return }
        let token = openingTailToken
        openingTailFrameTaskGeneration &+= 1
        openingTailFrameTask?.cancel()
        openingTailFrameTask = nil
        if let commandToken = openingTailCommandToken,
           command?.token == commandToken { clearCommand() }
        openingTailSettlementPending = false
        openingTailToken = nil
        openingTailTargetRenderedID = nil
        openingTailTargetSample = nil
        openingTailPresentation = nil
        openingTailCommandToken = nil
        openingTailCommandSemanticRevision = nil
        openingTailCommandGeometryRevision = nil
        openingTailCommandAttemptCount = 0
        openingTailPositioned = false
        openingTailRevealCompleted = false
        openingTailStableFrameCount = 0
        openingTailStableSemanticRevision = nil
        openingTailStableGeometryRevision = nil
        let continuation = openingTailContinuation
        openingTailContinuation = nil
        continuation?.resume(returning: positioningSucceeded)
        if let token { resumeOpeningTailFinalWaiters(token: token) }
    }

    private func resumeOpeningTailFinalWaiter(id: Int, token: Int) {
        guard let index = openingTailFinalWaiters.firstIndex(where: {
            $0.id == id && $0.token == token
        }) else { return }
        openingTailFinalWaiters.remove(at: index).continuation.resume()
    }

    private func resumeOpeningTailFinalWaiters(token: Int) {
        let admitted = openingTailFinalWaiters.filter { $0.token == token }
        openingTailFinalWaiters.removeAll { $0.token == token }
        admitted.forEach { $0.continuation.resume() }
    }

    private func advanceLayoutEpoch() {
        layoutEpoch &+= 1
        semanticFrames.removeAll(keepingCapacity: true)
        semanticFrameOrder.removeAll(keepingCapacity: true)
    }

    #if HOSTED_TEST
    var hostedSemanticFrameCount: Int { semanticFrames.count }
    var hostedDiscreteFollowRenderedIDs: Set<String> { discreteFollowRenderedIDs }
    var hostedIsNativeUserOwned: Bool { isNativeUserOwned }
    var hostedPendingNativeUserGeometry: Bool { pendingNativeUserGeometry }
    var hostedDirectTailReturnArmed: Bool { directTailReturnArmed }
    var hostedIsUserDrivenSettling: Bool { isUserDrivenSettling }

    func hostedWaitForFollowDecision(after revision: Int) async {
        guard hostedFollowDecisionRevision <= revision else { return }
        await withCheckedContinuation { continuation in
            hostedFollowDecisionWaiters.append(continuation)
        }
    }

    private func completeHostedFollowDecision() {
        hostedFollowDecisionRevision &+= 1
        let waiters = hostedFollowDecisionWaiters
        hostedFollowDecisionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

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
                else if hostedPrependSampleWaiters.count >= 8 {
                    continuation.resume(throwing: CancellationError())
                } else {
                    hostedPrependSampleWaiters.append(.init(id: id, continuation: continuation))
                }
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

    private func commitScrollAway() {
        userScrolledAway = true
        isAtBottom = false
        pendingGrowthFollow = false
        pendingUnattributedOlderMovement = false
        cancelAutomaticTasks()
    }

    private func releaseAtBottom() {
        let publishesSettlement = userScrolledAway || !isAtBottom
        followFrameTask?.cancel()
        boundaryCameFromViewportWithoutTailMovement = false
        followFrameTask = nil
        isAtBottom = true
        userScrolledAway = false
        hasUnreadContent = false
        pendingGrowthFollow = false
        pendingUnattributedOlderMovement = false
        if !isUserInteracting {
            isNativeUserOwned = false
            pendingNativeUserGeometry = false
            isUserDrivenSettling = false
        }
        if publishesSettlement { tailSettlementGeneration &+= 1 }
    }

    private static func isDirectUserPhase(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .tracking || phase == .decelerating
    }
}
