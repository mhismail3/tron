#if HOSTED_TEST
import SwiftUI

struct ChatHostedScrollState: Sendable {
    let isDetached: Bool
    let hasUnread: Bool
    let isWaitingForPrependSemanticFrame: Bool
}

struct ChatHostedObservation: Sendable {
    let revision: Int
    let geometry: ChatTranscriptGeometry
    let visibleRowIDs: [String]
    let rowFrames: [String: CGRect]
    let scrollSettledDistance: CGFloat?
    let scrollCommandCount: Int
    let automaticScrollCommandCount: Int
    let smoothAutomaticScrollCommandCount: Int
    let animatedEntranceCount: Int
    let offscreenEntranceResolutionCount: Int
    let geometryCallbackCount: Int
    let semanticFrameCallbackCount: Int
    let projectionSubmitCount: Int
    let projectionWorkAdmissionCount: Int
    let projectionInstallCount: Int
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
}

@MainActor
final class ChatHostedProbe {
    private var geometry = ChatTranscriptGeometry.zero
    private var rowFrames: [String: CGRect] = [:]
    private var rowFrameOrder: [String] = []
    private var scrollSettledDistance: CGFloat?
    private var scrollCommandCount = 0
    private var automaticScrollCommandCount = 0
    private var smoothAutomaticScrollCommandCount = 0
    private var animatedEntranceCount = 0
    private var offscreenEntranceResolutionCount = 0
    private var geometryCallbackCount = 0
    private var semanticFrameCallbackCount = 0
    private var projectionSubmitCount = 0
    private var projectionWorkAdmissionCount = 0
    private var projectionInstallCount = 0
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
    private var composerViewportControl: (() -> Void)?
    private var semanticResponseControl: (() -> Void)?
    private var frameControl: (() async throws -> Void)?
    private var stateControl: (() -> ChatHostedScrollState)?
    private var prependControl: (() -> Bool)?
    private var invalidatePresentationControl: (() -> Void)?
    private var prependPageContinuation: CheckedContinuation<Void, Error>?
    private var isReady = false
    private(set) var revision = 0
    private(set) var usesDrivenScrollAuthority = false

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
            geometry: geometry,
            visibleRowIDs: visibleRowIDs,
            rowFrames: rowFrames,
            scrollSettledDistance: scrollSettledDistance,
            scrollCommandCount: scrollCommandCount,
            automaticScrollCommandCount: automaticScrollCommandCount,
            smoothAutomaticScrollCommandCount: smoothAutomaticScrollCommandCount,
            animatedEntranceCount: animatedEntranceCount,
            offscreenEntranceResolutionCount: offscreenEntranceResolutionCount,
            geometryCallbackCount: geometryCallbackCount,
            semanticFrameCallbackCount: semanticFrameCallbackCount,
            projectionSubmitCount: projectionSubmitCount,
            projectionWorkAdmissionCount: projectionWorkAdmissionCount,
            projectionInstallCount: projectionInstallCount,
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

    func updateGeometry(_ value: ChatTranscriptGeometry) {
        geometryCallbackCount &+= 1
        geometry = value
        revision &+= 1
    }

    func updateRowFrame(id: String, frame: CGRect) {
        semanticFrameCallbackCount &+= 1
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
        revision &+= 1
    }

    func recordScrollSettle(distanceFromBottom: CGFloat) {
        guard scrollSettledDistance != distanceFromBottom else { return }
        scrollSettledDistance = distanceFromBottom
        revision &+= 1
    }

    func recordScrollCommand(isAutomatic: Bool, isSmooth: Bool) {
        scrollCommandCount &+= 1
        if isAutomatic {
            automaticScrollCommandCount &+= 1
            if isSmooth { smoothAutomaticScrollCommandCount &+= 1 }
        }
        revision &+= 1
    }

    func recordEntranceResolution(animated: Bool) {
        if animated { animatedEntranceCount &+= 1 }
        else { offscreenEntranceResolutionCount &+= 1 }
        revision &+= 1
    }

    func recordProjectionSubmit(startedWork: Bool) {
        projectionSubmitCount &+= 1
        if startedWork { projectionWorkAdmissionCount &+= 1 }
        revision &+= 1
    }

    func recordProjectionInstall(rowCount: Int, sourceOrdinal: Int) {
        projectionInstallCount &+= 1
        installedProjectionRowCount = max(0, rowCount)
        installedProjectionSourceOrdinal = max(0, sourceOrdinal)
        revision &+= 1
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
        composerViewport: @escaping () -> Void,
        semanticResponse: @escaping () -> Void,
        frame: @escaping () async throws -> Void,
        state: @escaping () -> ChatHostedScrollState,
        prepend: @escaping () -> Bool,
        invalidatePresentation: @escaping () -> Void
    ) {
        geometryControl = geometry
        phaseControl = phase
        nativeControl = native
        catchUpControl = catchUp
        composerViewportControl = composerViewport
        semanticResponseControl = semanticResponse
        frameControl = frame
        stateControl = state
        prependControl = prepend
        invalidatePresentationControl = invalidatePresentation
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

    func driveComposerViewportTransition() {
        controlEventCount &+= 1
        composerViewportControl?()
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

    func drivePresentationInvalidation() {
        controlEventCount &+= 1
        invalidatePresentationControl?()
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
