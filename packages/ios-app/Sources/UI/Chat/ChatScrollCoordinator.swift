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
    static let defaultOpeningTailTimeout: Duration = .milliseconds(750)
    static let liveGrowthFollowDuration = 0.16

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
            case .idle: return nil
            case .positioning(let context), .positioned(let context): return context
            case .postReveal(let context): return context.base
            }
        }
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
    private let clock: MonotonicClock
    private let openingTailTimeout: Duration
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
    private var pendingGrowthFollowAnimation: ChatScrollAnimation = .disabled
    /// A command write is not a native acknowledgement. Automatic tail
    /// commands remain owned until fresh geometry proves the physical tail.
    private var pendingAutomaticTailCommandToken: Int?
    /// The one correction issued for a physically invalid past-bottom sample.
    /// Its applied edge binding owns settlement until plausible geometry or
    /// direct cancellation; repeated stale samples cannot submit another write.
    private var pastBottomCorrectionCommandToken: Int?
    private var automaticTailCommandStartGeometryRevision: Int?
    private var automaticTailCommandStartOffsetY: CGFloat?
    private var pendingContinuousGrowthFollow = false
    private var discreteFollowRenderedIDs: Set<String> = []
    private var discreteFollowRenderedIDOrder: [String] = []
    private var pendingUnattributedOlderMovement = false
    private var userInteractionStartOffsetY: CGFloat?
    private var userInteractionStartDistanceFromBottom: CGFloat?
    private var bindingIsReleased = false
    private var openingTailPhase: OpeningTailPhase = .idle
    private var openingTailContinuation: CheckedContinuation<Bool, Never>?
    private var openingTailFinalWaiters: [OpeningTailFinalWaiter] = []
    private var nextOpeningTailFinalWaiterID = 0
    private var openingTailFrameTaskGeneration = 0
    private var geometryRevision = 0

    @ObservationIgnored private var followFrameTask: Task<Void, Never>?
    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    @ObservationIgnored private var prependTask: Task<Void, Never>?
    @ObservationIgnored private var prependTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var openingTailFrameTask: Task<Void, Never>?
    @ObservationIgnored private var openingTailTimeoutTask: Task<Void, Never>?

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

    init(
        frameScheduler: DisplayFrameScheduler = .displayLink,
        clock: MonotonicClock = .continuous,
        openingTailTimeout: Duration = ChatScrollCoordinator.defaultOpeningTailTimeout
    ) {
        self.frameScheduler = frameScheduler
        self.clock = clock
        self.openingTailTimeout = openingTailTimeout
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
        canAutomaticallyFollowIgnoringOpening && !openingTailPhase.isActive
    }

    private var canAutomaticallyFollowIgnoringOpening: Bool {
        !userScrolledAway && !isUserInteracting && !isNativeUserOwned
            && !pendingNativeUserGeometry && !isUserDrivenSettling
            && !isPrependingHistory && catchUpPhase == .none
    }

    private var openingTailSettlementPending: Bool { openingTailPhase.isActive }
    private var openingTailToken: Int? { openingTailPhase.context?.token }
    private var openingTailPresentation: Int? { openingTailPhase.context?.presentation }

    func resetForPresentation(
        _ presentation: Int? = nil,
        retainingVisibleViewport: Bool = false
    ) {
        cancelAllOwnedWork(result: .discarded)
        self.presentation = presentation ?? (self.presentation &+ 1)
        if retainingVisibleViewport {
            // A same-session generation handoff keeps the physical viewport
            // owner intact while the retained installed commit remains visible.
            // Preserve measured semantic frames until the replacement commit
            // emits its explicit installed-layout epoch. Clearing them here
            // would erase the detached reader's only viewport anchor.
            clearCommand()
            return
        }
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
        pendingAutomaticTailCommandToken = nil
        pastBottomCorrectionCommandToken = nil
        automaticTailCommandStartGeometryRevision = nil
        automaticTailCommandStartOffsetY = nil
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
        if let context = openingTailPhase.context,
           context.presentation == presentation,
           context.targetRenderedID == renderedID {
            switch openingTailPhase {
            case .positioning(var context):
                context.targetSample = semanticFrames[renderedID]
                openingTailPhase = .positioning(context)
            case .positioned(var context):
                context.targetSample = semanticFrames[renderedID]
                openingTailPhase = .positioned(context)
            case .postReveal(var context):
                context.base.targetSample = semanticFrames[renderedID]
                openingTailPhase = .postReveal(context)
            case .idle:
                break
            }
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
        guard !userScrolledAway, catchUpPhase == .none, !isPrependingHistory,
              !openingTailPhase.isActive else { return }
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
        if let finalGeometry {
            geometry = finalGeometry
            geometryRevision &+= 1
            acknowledgeAutomaticTailIfSettled(finalGeometry)
        }
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

        if let finalGeometry,
           requestPinnedTailCorrectionIfNeeded(
               finalGeometry,
               hasDirectUserAuthority: wasInteracting || wasSettling || hadUserInteraction
                   || pendingNativeUserGeometry || directTailReturnArmed
           ) {
            directTailReturnArmed = false
            return
        }
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

    /// Replays the geometry boundary for an installed layout even when native
    /// scroll geometry reports identical numeric values. SwiftUI can coalesce
    /// that observation while the semantic row frames still advance.
    func installedLayoutEpochChanged() {
        geometryRevision &+= 1
        evaluateLayoutMutationIfReady()
        evaluatePrependMeasurementIfReady()
    }

    func geometryChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        geometry = current
        geometryRevision &+= 1
        acknowledgeAutomaticTailIfSettled(current)
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
        if requestPinnedTailCorrectionIfNeeded(current, hasDirectUserAuthority: attributed) {
            return
        }

        if current.isAtCatchUpBoundary {
            admitTailBoundary(directlyOwned: attributed)
            if !preservesRejectedViewportAuthority || !isUserInteracting {
                directTailReturnArmed = false
            }
        } else {
            if isAtBottom != current.isAtBottom { isAtBottom = current.isAtBottom }
            if movedOlder && !attributed { pendingUnattributedOlderMovement = true }
            if attributed && movedOlder {
                // Publish detachment on the first measured upward movement,
                // not only after the native scroll phase settles. The catch-up
                // affordance should track the same live geometry that releases
                // it when the reader returns to the tail.
                commitScrollAway()
            }
        }
        pendingNativeUserGeometry = false
        if !isUserInteracting { hadUserInteraction = false }

        guard grew, previous.isValid, !userScrolledAway,
              catchUpPhase == .none, !isPrependingHistory else {
            if pendingGrowthFollow { scheduleTailFollow() }
            return
        }
        pendingGrowthFollow = true
        pendingContinuousGrowthFollow = true
        pendingGrowthFollowAnimation = .smooth(duration: Self.liveGrowthFollowDuration)
        scheduleTailFollow()
    }

    func viewportChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        geometry = current
        geometryRevision &+= 1
        acknowledgeAutomaticTailIfSettled(current)
        evaluateLayoutMutationIfReady()
        evaluatePrependMeasurementIfReady()
        evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        if openingTailSettlementPending { return }
        guard current.hasViewportChange(from: previous) else { return }
        pendingUnattributedOlderMovement = false
        let hasDirectUserAuthority = isUserInteracting || isUserDrivenSettling
            || pendingNativeUserGeometry || directTailReturnArmed
        if requestPinnedTailCorrectionIfNeeded(
            current,
            hasDirectUserAuthority: hasDirectUserAuthority
        ) {
            return
        }
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
        guard !isPrependingHistory else { return false }
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

    /// Test and preview seam for callback-order characterization.
    func requestOpeningTail(targetRenderedID: String?) {
        guard !isPrependingHistory else { return }
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
        guard case .positioned(let context) = openingTailPhase,
              context.presentation == presentation else { return }
        openingTailPhase = .postReveal(.init(base: context))
        scheduleOpeningTailFrame()
    }

    func waitForOpeningTailSettlement() async {
        guard let token = openingTailToken else { return }
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
        if case .positioning = openingTailPhase {
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

    /// A lifecycle-only graft publishes a complete local row without advancing
    /// canonical payload. It may request one pinned-tail follow, but deliberately
    /// leaves any authoritative projection mutation boundary untouched.
    func installedLifecycleChanged(_ installed: InstalledChatTranscript) {
        guard installed.hasUniqueDisplayedIDs, canAutomaticallyFollow else { return }
        pendingInstalledTailSettlement = true
        pendingGrowthFollow = true
        pendingContinuousGrowthFollow = true
        scheduleTailFollow()
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

    /// A geometry-admitted visible row insertion requests one coalesced smooth
    /// pinned-tail settlement. Detached/native-owned readers remain inert, and
    /// physical overshoot correction is forced nonanimated at publication.
    func discreteContentInserted(
        renderedID: String,
        followAnimation: ChatScrollAnimation = .smooth(
            duration: ChatScrollCoordinator.liveGrowthFollowDuration
        )
    ) {
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
        if case .smooth = followAnimation {
            pendingGrowthFollowAnimation = followAnimation
        }
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
        prependTimeoutTask?.cancel()
        prependTimeoutTask = Task { [weak self, clock] in
            do { try await clock.sleep(.seconds(8)) }
            catch { return }
            guard let self,
                  self.prependToken == token,
                  self.presentation == admittedPresentation else { return }
            self.prependTask?.cancel()
            self.finishPrepend(token: token, result: .failure)
        }

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

    private func acknowledgeAutomaticTailIfSettled(_ current: ChatTranscriptGeometry) {
        guard pendingAutomaticTailCommandToken != nil,
              command?.destination == .tail,
              !current.isPastBottomEdge,
              let startRevision = automaticTailCommandStartGeometryRevision,
              geometryRevision > startRevision else { return }
        let movedNativeViewport = automaticTailCommandStartOffsetY.map {
            abs(current.offsetY - $0) > 1
        } == true
        guard movedNativeViewport || current.isAtCatchUpBoundary else { return }
        pendingAutomaticTailCommandToken = nil
        pastBottomCorrectionCommandToken = nil
        automaticTailCommandStartGeometryRevision = nil
        automaticTailCommandStartOffsetY = nil
        command = nil
        commandRevision &+= 1
    }

    func commandApplied(_ applied: ChatScrollCommand) {
        guard command?.token == applied.token, applied.presentation == presentation else { return }
        let awaitsNativeTailEvidence = applied.origin == .automaticFollow
            && applied.destination == .tail
        if awaitsNativeTailEvidence {
            pendingAutomaticTailCommandToken = applied.token
            automaticTailCommandStartGeometryRevision = geometryRevision
            automaticTailCommandStartOffsetY = geometry.offsetY
        } else {
            command = nil
        }
        switch applied.destination {
        case .resetToBottom:
            bindingIsReleased = false
        case .releaseBinding:
            bindingIsReleased = true
        case .tail, .openingTail, .offsetY:
            bindingIsReleased = false
        }

        if case .positioning(let context) = openingTailPhase,
           context.presentation == applied.presentation,
           context.commandToken == applied.token {
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
        // Geometry can grow again while the previous automatic command is
        // still being consumed by SwiftUI. Keep that growth pending and issue
        // the next command only after the current token is acknowledged; two
        // writes in one render transaction are a primary source of jumps.
        if pendingGrowthFollow { scheduleTailFollow() }
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

    @discardableResult
    private func requestPinnedTailCorrectionIfNeeded(
        _ current: ChatTranscriptGeometry,
        hasDirectUserAuthority: Bool
    ) -> Bool {
        guard current.isPastBottomEdge,
              !hasDirectUserAuthority,
              !userScrolledAway,
              catchUpPhase == .none,
              !isPrependingHistory,
              !openingTailSettlementPending else { return false }
        // A released edge binding can retain an obsolete absolute offset when
        // canonical settlement, compaction, or reconciliation shortens/replaces
        // the stack. Negative bottom distance is clamped by presentation
        // geometry, so explicitly restore the physical tail instead of
        // accepting the blank overshoot as settled.
        isAtBottom = false
        isNativeUserOwned = false
        pendingNativeUserGeometry = false
        hadUserInteraction = false
        directTailReturnArmed = false
        if command?.origin == .automaticFollow,
           command?.destination == .tail,
           pendingAutomaticTailCommandToken != nil {
            if command?.token == pastBottomCorrectionCommandToken {
                // The one corrective edge binding is already applied. It owns
                // settlement until plausible geometry or direct cancellation;
                // repeated stale layout samples must not submit another write.
                return true
            }
            // An ordinary growth-tail token predating the structural shrink
            // cannot block this frame's proof-or-correction decision.
            clearCommand()
        }
        pendingGrowthFollow = true
        pendingContinuousGrowthFollow = true
        pendingInstalledTailSettlement = true
        scheduleTailFollow()
        return true
    }

    private func scheduleTailFollow() {
        guard pendingGrowthFollow, command == nil, canAutomaticallyFollow,
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
            let followAnimation = self.pendingGrowthFollowAnimation
            self.pendingGrowthFollowAnimation = .disabled
            if self.geometry.isPastBottomEdge
                || self.geometry.distanceFromBottom > ChatTranscriptGeometry.catchUpDistance {
                let correctsPastBottom = self.geometry.isPastBottomEdge
                self.publish(
                    .tail,
                    animation: correctsPastBottom ? .disabled : followAnimation,
                    origin: .automaticFollow
                )
                if correctsPastBottom {
                    self.pastBottomCorrectionCommandToken = self.command?.token
                }
            } else {
                // A previously applied edge binding may have corrected the
                // structural overshoot before this frame. Release it only after
                // the now-plausible native tail sample.
                self.requestBindingReleaseIfSettled()
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
        guard command != nil || pendingAutomaticTailCommandToken != nil else { return }
        command = nil
        pendingAutomaticTailCommandToken = nil
        pastBottomCorrectionCommandToken = nil
        automaticTailCommandStartGeometryRevision = nil
        automaticTailCommandStartOffsetY = nil
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
        pendingGrowthFollowAnimation = .disabled
        pendingAutomaticTailCommandToken = nil
        pastBottomCorrectionCommandToken = nil
        automaticTailCommandStartGeometryRevision = nil
        automaticTailCommandStartOffsetY = nil
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
        pendingGrowthFollowAnimation = .disabled
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
        prependTimeoutTask?.cancel()
        prependTimeoutTask = nil
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
        prependTimeoutTask?.cancel()
        prependTimeoutTask = nil
        if let correctionToken = prependCorrectionCommandToken,
           command?.token == correctionToken {
            clearCommand()
        }
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
        guard let context = openingTailPhase.context,
              context.presentation == presentation else { return }

        let targetSample = context.targetSample
        let hasCurrentTarget = targetSample?.layoutEpoch == layoutEpoch
        let targetIsVisible = hasCurrentTarget
            && targetSample!.frame.maxY > 0
            && targetSample!.frame.minY < geometry.containerHeight
        let physicallyPositioned = geometry.isPlausibleOpeningViewport
            && geometry.isAtCatchUpBoundary
            && targetIsVisible

        if physicallyPositioned {
            switch openingTailPhase {
            case .positioning(var context):
                context.commandToken = nil
                context.commandSemanticRevision = nil
                context.commandGeometryRevision = nil
                openingTailPhase = .positioned(context)
                openingTailTimeoutTask?.cancel()
                openingTailTimeoutTask = nil
                let continuation = openingTailContinuation
                openingTailContinuation = nil
                continuation?.resume(returning: true)
            case .positioned:
                break
            case .postReveal:
                if schedulesPositionedFrame { scheduleOpeningTailFrame() }
            case .idle:
                return
            }
            return
        }

        guard case .positioning(let context) = openingTailPhase else { return }
        if let openingCommandToken = context.commandToken {
            let hasFreshEvidence = semanticFrameRevision > (context.commandSemanticRevision ?? semanticFrameRevision)
                || geometryRevision > (context.commandGeometryRevision ?? geometryRevision)
            if hasFreshEvidence, command?.token != openingCommandToken {
                scheduleOpeningTailFrame()
            }
            return
        }

        guard canAutomaticallyFollowIgnoringOpening, command == nil,
              hasCurrentTarget || allowsUnrealizedTailCommand,
              geometry.isValid || allowsUnrealizedTailCommand else { return }
        publish(.openingTail(context.targetRenderedID), animation: .disabled, origin: .presentation)
        var updated = context
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
        let taskGeneration = openingTailFrameTaskGeneration
        let admittedToken = context.token
        let admittedPresentation = context.presentation
        let admittedSemanticRevision = semanticFrameRevision
        let admittedGeometryRevision = geometryRevision
        openingTailFrameTask = Task { [weak self, frameScheduler] in
            do {
                try await frameScheduler.nextFrame()
                try Task.checkCancellation()
            } catch {
                guard let self,
                      self.openingTailPhase.context?.token == admittedToken,
                      self.openingTailPhase.context?.presentation == admittedPresentation,
                      self.openingTailFrameTaskGeneration == taskGeneration else { return }
                // A display-frame helper can be cancelled independently of the
                // owning presentation task. Physical semantic/geometry callbacks
                // remain authoritative and may still complete positioning.
                self.openingTailFrameTask = nil
                return
            }
            guard let self,
                  self.openingTailPhase.context?.token == admittedToken,
                  self.openingTailPhase.context?.presentation == admittedPresentation,
                  self.openingTailFrameTaskGeneration == taskGeneration else { return }
            self.openingTailFrameTask = nil
            let revisionsAreStable = self.semanticFrameRevision == admittedSemanticRevision
                && self.geometryRevision == admittedGeometryRevision
            if case .positioning(var context) = self.openingTailPhase,
               let openingCommandToken = context.commandToken,
               self.command?.token != openingCommandToken {
                let hasFreshCommandEvidence = self.semanticFrameRevision
                    > (context.commandSemanticRevision ?? self.semanticFrameRevision)
                    || self.geometryRevision
                    > (context.commandGeometryRevision ?? self.geometryRevision)
                if hasFreshCommandEvidence || context.commandAttemptCount < 2 {
                    // Permit one bounded second exact-ID submission if SwiftUI
                    // consumed the first against a provisional lazy layout. Further
                    // writes require new semantic or geometry evidence.
                    context.commandToken = nil
                    context.commandSemanticRevision = nil
                    context.commandGeometryRevision = nil
                    self.openingTailPhase = .positioning(context)
                }
            }
            self.evaluateOpeningTailIfPossible(
                allowsUnrealizedTailCommand: true,
                schedulesPositionedFrame: false
            )
            guard self.openingTailPhase.context?.token == admittedToken,
                  self.openingTailPhase.context?.presentation == admittedPresentation,
                  self.openingTailFrameTaskGeneration == taskGeneration else { return }
            if case .postReveal(var context) = self.openingTailPhase,
               context.base.positionedBestEffort {
                context.stableFrameCount &+= 1
                self.openingTailPhase = .postReveal(context)
                if context.stableFrameCount >= 2 {
                    self.finishOpeningTailSettlement()
                } else {
                    self.scheduleOpeningTailFrame()
                }
            } else if case .postReveal(var context) = self.openingTailPhase,
               revisionsAreStable,
               self.openingTailViewportIsPhysicallySettled {
                if context.stableSemanticRevision == admittedSemanticRevision,
                   context.stableGeometryRevision == admittedGeometryRevision {
                    context.stableFrameCount &+= 1
                } else {
                    context.stableSemanticRevision = admittedSemanticRevision
                    context.stableGeometryRevision = admittedGeometryRevision
                    context.stableFrameCount = 1
                }
                self.openingTailPhase = .postReveal(context)
                if context.stableFrameCount >= 2 {
                    self.finishOpeningTailSettlement()
                } else {
                    self.scheduleOpeningTailFrame()
                }
            } else if case .postReveal(var context) = self.openingTailPhase {
                context.stableFrameCount = 0
                context.stableSemanticRevision = nil
                context.stableGeometryRevision = nil
                self.openingTailPhase = .postReveal(context)
                self.scheduleOpeningTailFrame()
            }
        }
    }

    private var openingTailViewportIsPhysicallySettled: Bool {
        guard let context = openingTailPhase.context,
              let targetSample = context.targetSample,
              targetSample.layoutEpoch == layoutEpoch else { return false }
        return geometry.isPlausibleOpeningViewport
            && geometry.isAtCatchUpBoundary
            && targetSample.frame.maxY > 0
            && targetSample.frame.minY < geometry.containerHeight
    }

    private func finishOpeningTailSettlement() {
        let token = openingTailToken
        let releasesBestEffortBinding = openingTailPhase.context?.positionedBestEffort == true
        openingTailTimeoutTask?.cancel()
        openingTailTimeoutTask = nil
        openingTailFrameTaskGeneration &+= 1
        openingTailFrameTask?.cancel()
        openingTailFrameTask = nil
        openingTailPhase = .idle
        let continuation = openingTailContinuation
        openingTailContinuation = nil
        continuation?.resume(returning: true)
        if let token { resumeOpeningTailFinalWaiters(token: token) }
        releaseAtBottom()
        if releasesBestEffortBinding, !bindingIsReleased, command == nil {
            publish(.releaseBinding, animation: .disabled, origin: .binding)
        } else {
            requestBindingReleaseIfSettled()
        }
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
        openingTailPhase = .idle
        let continuation = openingTailContinuation
        openingTailContinuation = nil
        continuation?.resume(returning: positioningSucceeded)
        if let token { resumeOpeningTailFinalWaiters(token: token) }
    }

    private func scheduleOpeningTailTimeout(token: Int, presentation: Int) {
        openingTailTimeoutTask?.cancel()
        openingTailTimeoutTask = Task { [weak self, clock, openingTailTimeout] in
            do {
                try await clock.sleep(openingTailTimeout)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self,
                  self.openingTailPhase.context?.token == token,
                  self.openingTailPhase.context?.presentation == presentation else { return }
            // Native proof is preferred, but presentation must not become
            // unavailable solely because SwiftUI omits/coalesces geometry.
            // The coordinator already made its bounded exact-ID attempts; keep
            // that binding and reveal the authoritative transcript best-effort.
            self.finishOpeningTailPositioningAfterTimeout(
                token: token,
                presentation: presentation
            )
        }
    }

    private func finishOpeningTailPositioningAfterTimeout(token: Int, presentation: Int) {
        guard case .positioning(var context) = openingTailPhase,
              context.token == token,
              context.presentation == presentation else { return }
        openingTailTimeoutTask = nil
        context.commandToken = nil
        context.commandSemanticRevision = nil
        context.commandGeometryRevision = nil
        context.positionedBestEffort = true
        openingTailPhase = .positioned(context)
        let continuation = openingTailContinuation
        openingTailContinuation = nil
        continuation?.resume(returning: true)
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
        pendingGrowthFollowAnimation = .disabled
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
