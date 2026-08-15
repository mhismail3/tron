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
        case prepend
        case binding
    }

    enum Destination: Equatable, Sendable {
        case resetToBottom
        case tail
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
    private var pendingUnattributedOlderMovement = false
    private var userInteractionStartOffsetY: CGFloat?
    private var userInteractionStartDistanceFromBottom: CGFloat?
    private var bindingIsReleased = false
    private var openingTailSettlementPending = false
    private var openingTailTargetRenderedID: String?
    private var openingTailPresentation: Int?
    private var openingTailExpectedFrameGeometryRevision: Int?
    private var geometryRevision = 0

    @ObservationIgnored private var followFrameTask: Task<Void, Never>?
    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    @ObservationIgnored private var prependTask: Task<Void, Never>?

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
    private var nextHostedCommandWaiterID = 0
    private var nextHostedPrependSampleWaiterID = 0
    #endif

    private var prependToken: Int?
    private var prependWasScrolledAway = false
    private var prependInterrupted = false
    private var prependAnchor: ChatSemanticAnchor?
    private var prependRenderedAnchorID: String?
    private var prependExpectedLayoutEpoch: Int?
    private var prependReadyForMeasurement = false
    private var prependRequiredSampleRevision = 0
    private var prependCorrectionCount = 0
    private var prependCorrectionCommandToken: Int?
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

    func beginInstalledPageLayoutEpoch() -> ChatInstalledLayoutEpoch {
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
        evaluatePrependMeasurementIfReady()
        if openingTailSettlementPending,
           openingTailPresentation == presentation,
           openingTailTargetRenderedID == renderedID {
            openingTailExpectedFrameGeometryRevision = geometryRevision
            settleOpeningTailIfPossible(allowsBoundarySettlement: false)
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
        if geometry.isAtCatchUpBoundary && !isUserInteracting {
            // A native binding may remain transiently owned after manual return;
            // at the measured tail it must not block keyboard following.
            isNativeUserOwned = false
            pendingNativeUserGeometry = false
            isUserDrivenSettling = false
        }
        pendingGrowthFollow = true
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
        if settleOpeningTailIfPossible(allowsBoundarySettlement: true) { return }
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

        guard grew, previous.isValid, !userScrolledAway, catchUpPhase == .none else { return }
        pendingGrowthFollow = true
        scheduleTailFollow()
    }

    func viewportChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        geometry = current
        geometryRevision &+= 1
        if settleOpeningTailIfPossible(allowsBoundarySettlement: true) { return }
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
        scheduleTailFollow()
    }

    /// Arms final opening placement for the exact installed timeline tail. The
    /// nil target is the explicit no-transcript path and needs no position write.
    func requestOpeningTail(targetRenderedID: String?) {
        clearOpeningTailSettlement()
        guard let targetRenderedID else { return }
        openingTailSettlementPending = true
        openingTailTargetRenderedID = targetRenderedID
        openingTailPresentation = presentation
        if semanticFrames[targetRenderedID]?.layoutEpoch == layoutEpoch {
            openingTailExpectedFrameGeometryRevision = geometryRevision
        }
        settleOpeningTailIfPossible(allowsBoundarySettlement: false)
    }

    func requestCatchUp(reduceMotion: Bool) {
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

    func semanticResponseArrived() {
        if shouldTrackUnreadResponse { hasUnreadContent = true }
    }

    @discardableResult
    func beginPrepend(
        anchor: ChatSemanticAnchor?,
        load: @escaping @MainActor @Sendable () async -> ChatPrependPage?,
        completion: @escaping @MainActor (PerformanceResult) -> Void
    ) -> Bool {
        guard !isPrependingHistory, let anchor,
              anchor.layoutEpoch == layoutEpoch,
              let admittedSample = semanticFrames[anchor.renderedID],
              admittedSample.layoutEpoch == anchor.layoutEpoch,
              abs(admittedSample.frame.minY - anchor.viewportOffsetY) <= 0.5,
              admittedSample.frame.maxY > 0,
              admittedSample.frame.minY < geometry.containerHeight else {
            completion(.discarded)
            return false
        }
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
        prependCorrectionCount = 0
        prependCorrectionCommandToken = nil
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
            settleOpeningTailIfPossible(allowsBoundarySettlement: false)
        case .releaseBinding:
            bindingIsReleased = true
        case .tail, .offsetY:
            bindingIsReleased = false
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

        if prependCorrectionCommandToken == applied.token {
            prependCorrectionCommandToken = nil
            prependRequiredSampleRevision = semanticFrameRevision
            prependReadyForMeasurement = true
        }
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

    private func evaluatePrependMeasurementIfReady() {
        guard prependReadyForMeasurement,
              prependCorrectionCommandToken == nil,
              let token = prependToken, !prependInterrupted,
              let anchor = prependAnchor,
              let renderedID = prependRenderedAnchorID,
              let expectedEpoch = prependExpectedLayoutEpoch,
              expectedEpoch == layoutEpoch,
              let sample = semanticFrames[renderedID],
              sample.layoutEpoch == expectedEpoch,
              sample.revision > prependRequiredSampleRevision else { return }
        prependReadyForMeasurement = false
        let residual = sample.frame.minY - anchor.viewportOffsetY
        maximumPrependSemanticExcursion = max(maximumPrependSemanticExcursion, abs(residual))
        if abs(residual) <= 1 {
            finishPrepend(token: token, result: .success)
            return
        }
        guard prependCorrectionCount < 2 else {
            finishPrepend(token: token, result: .failure)
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
              geometry.distanceFromBottom > ChatTranscriptGeometry.catchUpDistance,
              followFrameTask == nil else { return }
        let admittedPresentation = presentation
        followFrameTask = Task { [weak self, frameScheduler] in
            do {
                try await frameScheduler.nextFrame()
                try Task.checkCancellation()
            } catch { return }
            guard let self else { return }
            self.followFrameTask = nil
            guard self.presentation == admittedPresentation,
                  self.pendingGrowthFollow, self.canAutomaticallyFollow else { return }
            self.pendingGrowthFollow = false
            if self.geometry.distanceFromBottom > ChatTranscriptGeometry.catchUpDistance {
                self.publish(.tail, animation: .disabled, origin: .automaticFollow)
            }
        }
    }

    private func requestBindingReleaseIfSettled() {
        guard !bindingIsReleased, command == nil,
              followFrameTask == nil, catchUpTask == nil,
              catchUpPhase == .none, !isPrependingHistory,
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
        cancelAutomaticTasks()
        if isPrependingHistory {
            prependInterrupted = true
            if prependRenderedAnchorID != nil { finishPrepend(token: prependToken, result: .discarded) }
        }
        clearCommand()
    }

    private func cancelAutomaticTasks() {
        followFrameTask?.cancel()
        followFrameTask = nil
        pendingGrowthFollow = false
    }

    private func cancelAllOwnedWork(result: PerformanceResult) {
        clearOpeningTailSettlement()
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
        prependCorrectionCommandToken = nil
        isPrependingHistory = false
        #if HOSTED_TEST
        cancelHostedPrependSampleWaiters()
        #endif
    }

    private func finishPrepend(token: Int?, result: PerformanceResult) {
        guard token == prependToken else { return }
        prependTask = nil
        prependToken = nil
        prependAnchor = nil
        prependRenderedAnchorID = nil
        prependExpectedLayoutEpoch = nil
        prependReadyForMeasurement = false
        prependRequiredSampleRevision = semanticFrameRevision
        prependCorrectionCommandToken = nil
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
        if pendingGrowthFollow { scheduleTailFollow() }
    }

    @discardableResult
    private func settleOpeningTailIfPossible(allowsBoundarySettlement: Bool) -> Bool {
        guard openingTailSettlementPending,
              openingTailPresentation == presentation,
              let targetRenderedID = openingTailTargetRenderedID,
              let targetSample = semanticFrames[targetRenderedID],
              targetSample.layoutEpoch == layoutEpoch,
              let frameGeometryRevision = openingTailExpectedFrameGeometryRevision,
              geometry.isValid else { return false }

        if geometry.isAtCatchUpBoundary {
            // A boundary sample that predates an offscreen expected tail may be
            // transient pre-layout geometry. A later geometry callback or an
            // expected tail visibly inside the current viewport proves final
            // undersized/already-settled layout without arbitrary row evidence.
            let expectedTailIsVisible = targetSample.frame.maxY > 0
                && targetSample.frame.minY < geometry.containerHeight
            guard expectedTailIsVisible || (
                allowsBoundarySettlement && geometryRevision > frameGeometryRevision
            ) else { return false }
            clearOpeningTailSettlement()
            return false
        }

        guard canAutomaticallyFollow, command == nil else { return false }
        clearOpeningTailSettlement()
        publish(.tail, animation: .disabled, origin: .presentation)
        return true
    }

    private func clearOpeningTailSettlement() {
        openingTailSettlementPending = false
        openingTailTargetRenderedID = nil
        openingTailPresentation = nil
        openingTailExpectedFrameGeometryRevision = nil
    }

    private func advanceLayoutEpoch() {
        layoutEpoch &+= 1
        semanticFrames.removeAll(keepingCapacity: true)
        semanticFrameOrder.removeAll(keepingCapacity: true)
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
