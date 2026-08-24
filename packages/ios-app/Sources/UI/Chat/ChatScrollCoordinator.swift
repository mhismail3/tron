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

/// Owns explicit viewport intent plus opening, catch-up, semantic restore, and
/// prepend commands. Ordinary pinned growth is a native ScrollPosition layout
/// property and never enters this command channel.
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
        let anchor: ChatSemanticAnchor
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
    private(set) var maximumPrependSemanticExcursion: CGFloat = 0

    private let frameScheduler: DisplayFrameScheduler
    private let clock: MonotonicClock
    private let openingTailTimeout: Duration
    private var presentation = 0
    private var sequence = 0
    private var geometry = ChatTranscriptGeometry.zero
    private var geometryRevision = 0
    private var semanticFrames: [String: SemanticFrameSample] = [:]
    private var semanticFrameOrder: [String] = []
    private var semanticFrameRevision = 0
    private var openingTailPhase: OpeningTailPhase = .idle
    private var openingTailContinuation: CheckedContinuation<Bool, Never>?
    private var openingTailFinalWaiters: [OpeningTailFinalWaiter] = []
    private var nextOpeningTailFinalWaiterID = 0
    private var openingTailFrameTaskGeneration = 0
    private var catchUpPhase: CatchUpPhase = .none
    private var catchUpCommandToken: Int?
    private var catchUpUnreadBeforeJump = false
    private var layoutRestore: LayoutRestore?
    private var prepend: PrependContext?

    @ObservationIgnored private var catchUpTask: Task<Void, Never>?
    @ObservationIgnored private var layoutRestoreTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var prependTask: Task<Void, Never>?
    @ObservationIgnored private var prependTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var openingTailFrameTask: Task<Void, Never>?
    @ObservationIgnored private var openingTailTimeoutTask: Task<Void, Never>?

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
    var shouldTrackUnreadResponse: Bool { viewportMode == .anchored || catchUpPhase != .none }
    var isWaitingForPrependSemanticFrame: Bool {
        prepend?.readyForMeasurement == true && prepend?.correctionCommandToken == nil
    }
    var canAutomaticallyFollow: Bool {
        viewportMode == .pinned && !isUserInteracting && prepend == nil
            && catchUpPhase == .none && !openingTailPhase.isActive
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
        viewportMode.reduce(.presentationReset(retainingViewport: retainingVisibleViewport))
        clearCommand()
        guard !retainingVisibleViewport else { return }
        isAtBottom = true
        hasUnreadContent = false
        isUserInteracting = false
        geometry = .zero
        geometryRevision = 0
        advanceLayoutEpoch()
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
        semanticFrameOrder.removeAll { $0 == renderedID }
        semanticFrameOrder.append(renderedID)
        if semanticFrameOrder.count > 256 {
            let overflow = semanticFrameOrder.count - 256
            let removed = Array(semanticFrameOrder.prefix(overflow))
            semanticFrameOrder.removeFirst(overflow)
            for id in removed { semanticFrames[id] = nil }
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
        guard isPositionedByUser else { return }
        viewportMode.reduce(.userTookOver)
        isAtBottom = false
        abandonAutomaticTransactionsForDirectInteraction()
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
            viewportMode.reduce(.userTookOver)
            isAtBottom = false
            abandonAutomaticTransactionsForDirectInteraction()
            return
        }
        guard newPhase == .idle else { return }
        if wasDirect, geometry.isAtCatchUpBoundary {
            pinAtTail()
        }
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
        geometry = current
        geometryRevision &+= 1
        evaluateLayoutRestoreIfReady()
        evaluatePrependIfReady()
        evaluateOpeningTailIfPossible(allowsUnrealizedTailCommand: false)
        guard !openingTailSettlementPending else { return }
        let nextIsAtBottom = viewportMode == .pinned
            && (current.isAtBottom || current.isAtCatchUpBoundary)
        if isAtBottom != nextIsAtBottom { isAtBottom = nextIsAtBottom }
        if catchUpPhase == .settling, current.isAtCatchUpBoundary {
            finishCatchUpPinned()
        }
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

    func installedLifecycleChanged(_ installed: InstalledChatTranscript) {
        // Pinned lifecycle growth is absorbed by the held bottom edge. Anchored
        // readers intentionally receive no command.
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

    func discreteContentInserted(renderedID: String) {
        // Native edge pinning owns growth. This callback remains the entrance
        // admission seam but emits no viewport command.
    }

    func submitted() {
        viewportMode.reduce(.submitted)
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
        guard canRequestHistoryPage else {
            completion(.discarded)
            return false
        }
        // Loading earlier is explicit reader intent. It supersedes a pending
        // semantic-restore command before anchored or unanchored paging starts,
        // so that stale write cannot land after page installation. Catch-up and
        // opening retain their stronger ownership and reject paging above.
        cancelLayoutRestore()
        clearCommand()
        guard let anchor, anchor.layoutEpoch == layoutEpoch,
              let sample = semanticFrames[anchor.renderedID],
              sample.layoutEpoch == anchor.layoutEpoch,
              abs(sample.frame.minY - anchor.viewportOffsetY) <= 0.5,
              sample.frame.maxY > 0,
              sample.frame.minY < geometry.containerHeight else {
            completion(.discarded)
            return false
        }
        sequence &+= 1
        let token = sequence
        let admittedPresentation = presentation
        viewportMode.reduce(.prependBegan)
        prepend = PrependContext(
            token: token,
            anchor: anchor,
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
            let page = await load()
            guard let self, var context = self.prepend,
                  context.token == token,
                  self.presentation == admittedPresentation else { return }
            self.prependTask = nil
            guard let page,
                  page.installedLayout.value == self.layoutEpoch,
                  page.installedLayout.value != anchor.layoutEpoch,
                  !context.interrupted else {
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
        return true
    }

    func commandApplied(_ applied: ChatScrollCommand) {
        guard command?.token == applied.token, applied.presentation == presentation else { return }
        command = nil
        commandRevision &+= 1

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
              let renderedID = context.renderedAnchorID,
              context.expectedLayoutEpoch == layoutEpoch,
              let sample = semanticFrames[renderedID], sample.layoutEpoch == layoutEpoch,
              sample.revision > context.requiredSampleRevision,
              geometryRevision > context.requiredGeometryRevision else { return }
        context.readyForMeasurement = false
        let residual = sample.frame.minY - context.anchor.viewportOffsetY
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
            capturedViewportOffsetY: context.anchor.viewportOffsetY,
            installedFrameMinY: sample.frame.minY
        )
        publish(.offsetY(requested), animation: .disabled, origin: .prepend)
        context.correctionCommandToken = command?.token
        prepend = context
    }

    private func recordPrependExcursionIfOwned(renderedID: String, layoutEpoch: Int, frame: CGRect) {
        guard let context = prepend, context.renderedAnchorID == renderedID,
              context.expectedLayoutEpoch == layoutEpoch else { return }
        maximumPrependSemanticExcursion = max(
            maximumPrependSemanticExcursion,
            abs(frame.minY - context.anchor.viewportOffsetY)
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
        let physicallyPositioned = geometry.isPlausibleOpeningViewport
            && geometry.isAtCatchUpBoundary && targetIsVisible
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

    private var openingTailViewportIsPhysicallySettled: Bool {
        guard let sample = openingTailPhase.context?.targetSample,
              sample.layoutEpoch == layoutEpoch else { return false }
        return geometry.isPlausibleOpeningViewport && geometry.isAtCatchUpBoundary
            && sample.frame.maxY > 0 && sample.frame.minY < geometry.containerHeight
    }

    private func finishOpeningTailSettlement() {
        let token = openingTailToken
        openingTailTimeoutTask?.cancel()
        openingTailTimeoutTask = nil
        openingTailFrameTaskGeneration &+= 1
        openingTailFrameTask?.cancel()
        openingTailFrameTask = nil
        openingTailPhase = .idle
        openingTailContinuation?.resume(returning: true)
        openingTailContinuation = nil
        if let token { resumeOpeningTailFinalWaiters(token: token) }
        viewportMode.reduce(.opened)
        isAtBottom = true
        tailSettlementGeneration &+= 1
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
            guard let self, case .positioning(var value) = self.openingTailPhase,
                  value.token == token, value.presentation == presentation else { return }
            self.clearOpeningCommand(matching: value.commandToken)
            value.commandToken = nil
            value.positionedBestEffort = true
            self.openingTailPhase = .positioned(value)
            self.openingTailContinuation?.resume(returning: true)
            self.openingTailContinuation = nil
        }
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
        if changed { tailSettlementGeneration &+= 1 }
    }

    private func finishCatchUpPinned() {
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
        if restoringAnchored, wasActive {
            viewportMode.reduce(.userTookOver)
            isAtBottom = false
            hasUnreadContent = catchUpUnreadBeforeJump || hasUnreadContent
        }
        catchUpUnreadBeforeJump = false
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
        layoutRestore = nil
    }

    private func finishPrepend(result: PerformanceResult) {
        guard let context = prepend else { return }
        prependTask = nil
        prependTimeoutTask?.cancel()
        prependTimeoutTask = nil
        if let token = context.correctionCommandToken, command?.token == token { clearCommand() }
        prepend = nil
        viewportMode.reduce(.prependEnded)
        #if HOSTED_TEST
        cancelHostedPrependSampleWaiters()
        #endif
        context.completion(result)
    }

    private func cancelAllOwnedWork(result: PerformanceResult) {
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

    private func publish(
        _ destination: ChatScrollCommand.Destination,
        animation: ChatScrollAnimation,
        origin: ChatScrollCommand.Origin
    ) {
        guard command == nil else { return }
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
        guard command != nil else { return }
        command = nil
        commandRevision &+= 1
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
