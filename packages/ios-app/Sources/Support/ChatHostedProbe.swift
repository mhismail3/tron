#if HOSTED_TEST
import SwiftUI

struct ChatHostedScrollState: Sendable {
    let isDetached: Bool
    let hasUnread: Bool
    let isWaitingForPrependSemanticFrame: Bool
}

struct ChatHostedGeometryTraceSample: Sendable, Equatable {
    let frame: Int
    let offsetY: CGFloat
    let bottomInset: CGFloat
    let composerHeight: CGFloat
    let rowFrames: [String: CGRect]
}

struct ChatHostedObservation: Sendable {
    let revision: Int
    let geometryTrace: [ChatHostedGeometryTraceSample]
    let processRoutes: [String]
    let geometry: ChatTranscriptGeometry
    let visibleRowIDs: [String]
    let rowFrames: [String: CGRect]
    let scrollSettledDistance: CGFloat?
    let scrollCommandCount: Int
    let tailMaterializationCommandCount: Int
    let targetReleaseCount: Int
    let physicalTailRepairCommandCount: Int
    let automaticScrollCommandCount: Int
    let smoothAutomaticScrollCommandCount: Int
    let animatedEntranceCount: Int
    let lastAnimatedEntranceSourceOrdinal: Int?
    let offscreenEntranceResolutionCount: Int
    let geometryCallbackCount: Int
    let semanticFrameCallbackCount: Int
    let projectionSubmitCount: Int
    let projectionWorkAdmissionCount: Int
    let projectionInstallCount: Int
    let committedHistoryRowEvaluationCount: Int
    let remountedWhileSemanticIDDisplayed: Int
    let physicalRowAppearanceCounts: [String: Int]
    let physicalRowDisappearanceCounts: [String: Int]
    let toolChipSamples: [ToolChipInstrumentationSample]
    let installedProjectionRowCount: Int
    let installedProjectionSourceOrdinal: Int?
    let maximumSemanticExcursion: CGFloat
    let controlEventCount: Int
    let isDetached: Bool
    let hasUnread: Bool
    let prependLoadWaiting: Bool
    let prependSemanticFrameWaiting: Bool
    let prependCompletionResult: PerformanceResult?
    let readyFrameCompletionCount: Int
    let isReady: Bool

    var composerHeight: CGFloat { geometryTrace.last?.composerHeight ?? 0 }

    var hasMonotonicOffsetY: Bool {
        guard geometryTrace.count > 2 else { return true }
        let deltas = zip(geometryTrace, geometryTrace.dropFirst()).map {
            $1.offsetY - $0.offsetY
        }.filter { abs($0) > 1 }
        guard let first = deltas.first else { return true }
        return deltas.allSatisfy { $0.sign == first.sign }
    }
}

enum ChatHostedScrollCallbackMode: Sendable {
    case synthetic
    case native
}

@MainActor
final class ChatHostedProbe {
    let scrollCallbackMode: ChatHostedScrollCallbackMode
    private var geometry = ChatTranscriptGeometry.zero
    private var composerHeight: CGFloat = 0
    private var geometryTrace: [ChatHostedGeometryTraceSample] = []
    private var processRoutes: [String] = []
    private var rowFrames: [String: CGRect] = [:]
    private var rowFrameOrder: [String] = []
    private var rowFrameGeneration: Int?
    private var pendingRowFramesByGeneration: [Int: [String: CGRect]] = [:]
    private var scrollSettledDistance: CGFloat?
    private var scrollCommandCount = 0
    private var tailMaterializationCommandCount = 0
    private var targetReleaseCount = 0
    private var physicalTailRepairCommandCount = 0
    private var automaticScrollCommandCount = 0
    private var smoothAutomaticScrollCommandCount = 0
    private var animatedEntranceCount = 0
    private var lastAnimatedEntranceSourceOrdinal: Int?
    private var offscreenEntranceResolutionCount = 0
    private var geometryCallbackCount = 0
    private var semanticFrameCallbackCount = 0
    private var projectionSubmitCount = 0
    private var projectionWorkAdmissionCount = 0
    private var projectionInstallCount = 0
    private var committedHistoryRowEvaluationCount = 0
    private var remountedWhileSemanticIDDisplayed = 0
    private var physicalRowAppearanceCounts: [String: Int] = [:]
    private var physicalRowDisappearanceCounts: [String: Int] = [:]
    private var toolChipSamples: [ToolChipInstrumentationSample] = []
    private var renderedIDBySemanticID: [String: String] = [:]
    private var installedProjectionRowCount = 0
    private var installedProjectionSourceOrdinal: Int?
    private var maximumSemanticExcursion: CGFloat = 0
    private var controlEventCount = 0
    private var isDetached = false
    private var hasUnread = false
    private var prependLoadWaiting = false
    private var prependSemanticFrameWaiting = false
    private var prependCompletionResult: PerformanceResult?
    private var readyFrameCompletionCount = 0
    private var geometryControl: ((ChatTranscriptGeometry, ChatTranscriptGeometry, Bool) -> Void)?
    private var phaseControl: ((ScrollPhase, ScrollPhase, ChatTranscriptGeometry?) -> Void)?
    private var nativeControl: ((Bool) -> Void)?
    private var catchUpControl: ((Bool) -> Void)?
    private var semanticResponseControl: (() -> Void)?
    private var submitPromptControl: (() -> Void)?
    private var frameControl: (() async throws -> Void)?
    private var stateControl: (() -> ChatHostedScrollState)?
    private var prependControl: (() -> Bool)?
    private var reapplyPinnedPositionControl: (() -> Void)?
    private var invalidatePresentationControl: (() -> Void)?
    private var reopenPresentationControl: (() async -> Void)?
    private var cancelPresentationControl: (() -> Void)?
    private var nextProjectionInstallControl: (@MainActor (Int) -> Void)?
    private var prependPageContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private(set) var revision = 0
    private(set) var usesDrivenScrollAuthority = false

    init(scrollCallbackMode: ChatHostedScrollCallbackMode = .synthetic) {
        self.scrollCallbackMode = scrollCallbackMode
    }

    var admitsNativeScrollCallbacks: Bool {
        scrollCallbackMode == .native || !usesDrivenScrollAuthority
    }

    var observation: ChatHostedObservation {
        let visibleRowIDs = rowFrames
            .filter { $0.value.maxY > 0 && $0.value.minY < geometry.containerHeight }
            .sorted {
                if $0.value.minY != $1.value.minY { return $0.value.minY < $1.value.minY }
                return $0.key < $1.key
            }
            .map(\.key)
        return ChatHostedObservation(
            revision: revision,
            geometryTrace: geometryTrace,
            processRoutes: processRoutes,
            geometry: geometry,
            visibleRowIDs: visibleRowIDs,
            rowFrames: rowFrames,
            scrollSettledDistance: scrollSettledDistance,
            scrollCommandCount: scrollCommandCount,
            tailMaterializationCommandCount: tailMaterializationCommandCount,
            targetReleaseCount: targetReleaseCount,
            physicalTailRepairCommandCount: physicalTailRepairCommandCount,
            automaticScrollCommandCount: automaticScrollCommandCount,
            smoothAutomaticScrollCommandCount: smoothAutomaticScrollCommandCount,
            animatedEntranceCount: animatedEntranceCount,
            lastAnimatedEntranceSourceOrdinal: lastAnimatedEntranceSourceOrdinal,
            offscreenEntranceResolutionCount: offscreenEntranceResolutionCount,
            geometryCallbackCount: geometryCallbackCount,
            semanticFrameCallbackCount: semanticFrameCallbackCount,
            projectionSubmitCount: projectionSubmitCount,
            projectionWorkAdmissionCount: projectionWorkAdmissionCount,
            projectionInstallCount: projectionInstallCount,
            committedHistoryRowEvaluationCount: committedHistoryRowEvaluationCount,
            remountedWhileSemanticIDDisplayed: remountedWhileSemanticIDDisplayed,
            physicalRowAppearanceCounts: physicalRowAppearanceCounts,
            physicalRowDisappearanceCounts: physicalRowDisappearanceCounts,
            toolChipSamples: toolChipSamples,
            installedProjectionRowCount: installedProjectionRowCount,
            installedProjectionSourceOrdinal: installedProjectionSourceOrdinal,
            maximumSemanticExcursion: maximumSemanticExcursion,
            controlEventCount: controlEventCount,
            isDetached: isDetached,
            hasUnread: hasUnread,
            prependLoadWaiting: prependLoadWaiting,
            prependSemanticFrameWaiting: prependSemanticFrameWaiting,
            prependCompletionResult: prependCompletionResult,
            readyFrameCompletionCount: readyFrameCompletionCount,
            isReady: isReady
        )
    }

    func recordProcessRoute() {
        processRoutes.append("processes")
        if processRoutes.count > 32 { processRoutes.removeFirst(processRoutes.count - 32) }
        revision &+= 1
    }

    func updateGeometry(_ value: ChatTranscriptGeometry) {
        geometryCallbackCount &+= 1
        geometry = value
        recordGeometryTrace()
        revision &+= 1
    }

    func recordComposerHeight(_ value: CGFloat) {
        guard value.isFinite, value >= 0 else { return }
        composerHeight = value
        recordGeometryTrace()
        revision &+= 1
    }

    private func recordGeometryTrace() {
        if let previous = geometryTrace.last,
           previous.offsetY == geometry.offsetY,
           previous.bottomInset == geometry.bottomInset,
           previous.composerHeight == composerHeight,
           previous.rowFrames == rowFrames {
            return
        }
        geometryTrace.append(ChatHostedGeometryTraceSample(
            frame: geometryTrace.last.map { $0.frame + 1 } ?? 0,
            offsetY: geometry.offsetY,
            bottomInset: geometry.bottomInset,
            composerHeight: composerHeight,
            rowFrames: rowFrames
        ))
        if geometryTrace.count > 240 {
            geometryTrace.removeFirst(geometryTrace.count - 240)
        }
    }

    func updateRowFrame(id: String, frame: CGRect, generation: Int? = nil) {
        if let generation {
            if let current = rowFrameGeneration {
                if generation < current { return }
                if generation > current {
                    bufferFutureRowFrame(id: id, frame: frame, generation: generation)
                    return
                }
            } else {
                bufferFutureRowFrame(id: id, frame: frame, generation: generation)
                return
            }
        }
        admitCurrentRowFrame(id: id, frame: frame)
    }

    private func bufferFutureRowFrame(id: String, frame: CGRect, generation: Int) {
        var frames = pendingRowFramesByGeneration[generation, default: [:]]
        frames[id] = frame
        if frames.count > 256 {
            for key in frames.keys.sorted().prefix(frames.count - 256) { frames[key] = nil }
        }
        pendingRowFramesByGeneration[generation] = frames
        let retainedGenerations = Set(pendingRowFramesByGeneration.keys.sorted().suffix(4))
        pendingRowFramesByGeneration = pendingRowFramesByGeneration
            .filter { retainedGenerations.contains($0.key) }
        semanticFrameCallbackCount &+= 1
        revision &+= 1
    }

    private func admitCurrentRowFrame(
        id: String,
        frame: CGRect,
        recordsCallback: Bool = true
    ) {
        if recordsCallback { semanticFrameCallbackCount &+= 1 }
        rowFrames[id] = frame
        rowFrameOrder.removeAll { $0 == id }
        rowFrameOrder.append(id)
        if rowFrameOrder.count > 256 {
            let overflow = rowFrameOrder.count - 256
            let removed = Array(rowFrameOrder.prefix(overflow))
            rowFrameOrder.removeFirst(overflow)
            for removedID in removed { rowFrames[removedID] = nil }
        }
        refreshControlledState()
        recordGeometryTrace()
        revision &+= 1
    }

    func recordScrollSettle(distanceFromBottom: CGFloat) {
        guard scrollSettledDistance != distanceFromBottom else { return }
        scrollSettledDistance = distanceFromBottom
        revision &+= 1
    }

    func recordScrollCommand(
        isAutomatic: Bool,
        isSmooth: Bool,
        origin: ChatScrollCommand.Origin? = nil
    ) {
        scrollCommandCount &+= 1
        if origin == .tailMaterialization { tailMaterializationCommandCount &+= 1 }
        if origin == .physicalTailRepair { physicalTailRepairCommandCount &+= 1 }
        if isAutomatic {
            automaticScrollCommandCount &+= 1
            if isSmooth { smoothAutomaticScrollCommandCount &+= 1 }
        }
        revision &+= 1
    }

    func recordTargetRelease() {
        targetReleaseCount &+= 1
        revision &+= 1
    }

    func recordEntranceResolution(animated: Bool, sourceOrdinal: Int) {
        if animated {
            animatedEntranceCount &+= 1
            lastAnimatedEntranceSourceOrdinal = sourceOrdinal
        } else {
            offscreenEntranceResolutionCount &+= 1
        }
        revision &+= 1
    }

    func recordProjectionSubmit(startedWork: Bool) {
        projectionSubmitCount &+= 1
        if startedWork { projectionWorkAdmissionCount &+= 1 }
        revision &+= 1
    }

    func recordToolChip(_ sample: ToolChipInstrumentationSample) {
        toolChipSamples.append(sample)
        if toolChipSamples.count > 128 {
            toolChipSamples.removeFirst(toolChipSamples.count - 128)
        }
        revision &+= 1
    }

    func recordPhysicalRowAppearance(id: String) {
        Self.incrementBoundedCount(id: id, counts: &physicalRowAppearanceCounts)
        revision &+= 1
    }

    func recordPhysicalRowDisappearance(id: String) {
        Self.incrementBoundedCount(id: id, counts: &physicalRowDisappearanceCounts)
        revision &+= 1
    }

    private static func incrementBoundedCount(id: String, counts: inout [String: Int]) {
        guard !id.isEmpty else { return }
        if counts[id] == nil, counts.count >= 256,
           let retired = counts.keys.sorted().first {
            counts[retired] = nil
        }
        counts[id, default: 0] &+= 1
    }

    func recordCommittedHistoryRowEvaluation() {
        committedHistoryRowEvaluationCount &+= 1
        revision &+= 1
    }

    func recordProjectionInstall(
        rowCount: Int,
        sourceOrdinal: Int,
        nextRenderedIDBySemanticID: [String: String]
    ) {
        for (semanticID, previousRenderedID) in renderedIDBySemanticID {
            if let nextRenderedID = nextRenderedIDBySemanticID[semanticID],
               nextRenderedID != previousRenderedID {
                remountedWhileSemanticIDDisplayed &+= 1
            }
        }
        let previousPhysicalIDs = Set(renderedIDBySemanticID.values)
        let nextPhysicalIDs = Set(nextRenderedIDBySemanticID.values)
        let preservesLayout = rowFrameGeneration != nil
            && rowCount == installedProjectionRowCount
            && previousPhysicalIDs == nextPhysicalIDs
            && renderedIDBySemanticID.allSatisfy {
                nextRenderedIDBySemanticID[$0.key] == $0.value
            }
        let retainedFrames = preservesLayout ? rowFrames : [:]
        let retainedOrder = preservesLayout ? rowFrameOrder : []
        renderedIDBySemanticID = nextRenderedIDBySemanticID
        if rowFrameGeneration != sourceOrdinal {
            rowFrames = retainedFrames
            rowFrameOrder = retainedOrder
            rowFrameGeneration = sourceOrdinal
            if let pending = pendingRowFramesByGeneration.removeValue(forKey: sourceOrdinal) {
                for (id, frame) in pending {
                    admitCurrentRowFrame(id: id, frame: frame, recordsCallback: false)
                }
            }
            pendingRowFramesByGeneration = pendingRowFramesByGeneration
                .filter { $0.key > sourceOrdinal }
        }
        projectionInstallCount &+= 1
        installedProjectionRowCount = max(0, rowCount)
        installedProjectionSourceOrdinal = max(0, sourceOrdinal)
        revision &+= 1
        let control = nextProjectionInstallControl
        nextProjectionInstallControl = nil
        control?(sourceOrdinal)
    }

    func onNextProjectionInstall(_ control: @escaping @MainActor (Int) -> Void) {
        nextProjectionInstallControl = control
    }

    func recordMaximumSemanticExcursion(_ value: CGFloat) {
        guard value > maximumSemanticExcursion else { return }
        maximumSemanticExcursion = value
        revision &+= 1
    }

    func installScrollControls(
        geometry: @escaping (ChatTranscriptGeometry, ChatTranscriptGeometry, Bool) -> Void,
        phase: @escaping (ScrollPhase, ScrollPhase, ChatTranscriptGeometry?) -> Void,
        native: @escaping (Bool) -> Void,
        catchUp: @escaping (Bool) -> Void,
        semanticResponse: @escaping () -> Void,
        submitPrompt: @escaping () -> Void,
        frame: @escaping () async throws -> Void,
        state: @escaping () -> ChatHostedScrollState,
        prepend: @escaping () -> Bool,
        reapplyPinnedPosition: @escaping () -> Void,
        invalidatePresentation: @escaping () -> Void,
        reopenPresentation: @escaping () async -> Void,
        cancelPresentation: @escaping () -> Void
    ) {
        geometryControl = geometry
        phaseControl = phase
        nativeControl = native
        catchUpControl = catchUp
        semanticResponseControl = semanticResponse
        submitPromptControl = submitPrompt
        frameControl = frame
        stateControl = state
        prependControl = prepend
        reapplyPinnedPositionControl = reapplyPinnedPosition
        invalidatePresentationControl = invalidatePresentation
        reopenPresentationControl = reopenPresentation
        cancelPresentationControl = cancelPresentation
        refreshControlledState()
    }

    func driveGeometry(
        previous: ChatTranscriptGeometry,
        current: ChatTranscriptGeometry,
        viewport: Bool = false
    ) {
        usesDrivenScrollAuthority = true
        controlEventCount &+= 1
        geometryControl?(previous, current, viewport)
        refreshControlledState()
        revision &+= 1
    }

    func drivePhase(from: ScrollPhase, to: ScrollPhase, geometry: ChatTranscriptGeometry?) {
        usesDrivenScrollAuthority = true
        controlEventCount &+= 1
        phaseControl?(from, to, geometry)
        refreshControlledState()
        revision &+= 1
    }

    func driveNativeOwnership(_ owned: Bool) {
        usesDrivenScrollAuthority = true
        controlEventCount &+= 1
        nativeControl?(owned)
        refreshControlledState()
        revision &+= 1
    }

    func driveSemanticResponse() {
        controlEventCount &+= 1
        semanticResponseControl?()
        refreshControlledState()
        revision &+= 1
    }

    func driveCatchUp(reduceMotion: Bool) {
        controlEventCount &+= 1
        catchUpControl?(reduceMotion)
        refreshControlledState()
        revision &+= 1
    }

    func submitPrompt() {
        controlEventCount &+= 1
        submitPromptControl?()
        refreshControlledState()
        revision &+= 1
    }

    func drivePrepend() -> Bool {
        prependCompletionResult = nil
        controlEventCount &+= 1
        let began = prependControl?() ?? false
        refreshControlledState()
        revision &+= 1
        return began
    }

    func waitForPrependPageRelease() async throws {
        prependLoadWaiting = true
        revision &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { prependPageContinuation = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.cancelPrependPageWait() }
        }
    }

    func releasePrependPage() {
        prependLoadWaiting = false
        revision &+= 1
        prependPageContinuation?.resume()
        prependPageContinuation = nil
    }

    func drivePinnedPositionReapplication() {
        controlEventCount &+= 1
        reapplyPinnedPositionControl?()
        refreshControlledState()
        revision &+= 1
    }

    func drivePresentationInvalidation() {
        controlEventCount &+= 1
        invalidatePresentationControl?()
        refreshControlledState()
        revision &+= 1
    }

    func reopenPresentation() async {
        controlEventCount &+= 1
        await reopenPresentationControl?()
        refreshControlledState()
        revision &+= 1
    }

    func cancelPresentation() {
        cancelPresentationControl?()
        refreshControlledState()
        revision &+= 1
    }

    func recordPrependCompletion(_ result: PerformanceResult) {
        prependCompletionResult = result
        refreshControlledState()
        revision &+= 1
    }

    private func cancelPrependPageWait() {
        prependLoadWaiting = false
        prependPageContinuation?.resume(throwing: CancellationError())
        prependPageContinuation = nil
        revision &+= 1
    }

    func driveFrameBoundary() async throws {
        controlEventCount &+= 1
        revision &+= 1
        try await frameControl?()
    }

    private func refreshControlledState() {
        guard let state = stateControl?() else { return }
        isDetached = state.isDetached
        hasUnread = state.hasUnread
        prependSemanticFrameWaiting = state.isWaitingForPrependSemanticFrame
    }

    func recordReadyFrameCompletion() {
        readyFrameCompletionCount &+= 1
        revision &+= 1
    }

    func markReady() {
        guard !isReady else { return }
        isReady = true
        revision &+= 1
    }
}
#endif
