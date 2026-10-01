/// Whether a mounted row's height changes after it mounts are row-stability
/// evidence. A row that is streaming, running its entrance, or being replaced
/// changes its own height as part of its presentation, so it is excluded
/// rather than counted; the tail marker is not a row at all.
///
/// It lives outside the hosted probe's `HOSTED_TEST` block because the hosted
/// recorder protocol that carries it is compiled in every build.
enum ChatHostedRowStability: Sendable {
    case settled
    case excluded
    case notARow
}

#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Test-only mounted UIKit evidence, queried at a display boundary. Unlike the
/// semantic callback cache, this cannot report a frame after native unmount.
final class ChatHostedNativeRowMarker: UIView {
    var physicalID = ""
    var semanticID = ""
    var hostIdentity = UUID()
}

@MainActor
final class ReadOnlySubagentHostedProbe {
    weak var store: ReadOnlySubagentSessionStore?
}

extension EnvironmentValues {
    @Entry var readOnlySubagentHostedProbe: ReadOnlySubagentHostedProbe? = nil
}

/// Sheet rows do not otherwise own a hosted lifetime token. The native marker's
/// identity is created once per mount, never rewritten by a value update.
struct ChatHostedStableRowProbe: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> ChatHostedNativeRowMarker { ChatHostedNativeRowMarker() }
    func updateUIView(_ view: ChatHostedNativeRowMarker, context: Context) {
        view.physicalID = id
        view.semanticID = id
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }
}

struct ChatHostedObstructionProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ChatHostedObstructionMarker { ChatHostedObstructionMarker() }
    func updateUIView(_ uiView: ChatHostedObstructionMarker, context: Context) {}
}

final class ChatHostedObstructionMarker: UIView {}

struct ChatHostedNativeRowProbe: UIViewRepresentable {
    static let composerID = "hosted-composer"
    let physicalID: String
    let semanticID: String
    let identity: UUID

    func makeUIView(context: Context) -> ChatHostedNativeRowMarker {
        let view = ChatHostedNativeRowMarker()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: ChatHostedNativeRowMarker, context: Context) {
        view.physicalID = physicalID
        view.semanticID = semanticID
        view.hostIdentity = identity
    }
}

/// One row's height history under one installed projection. `firstHeight` is
/// the height of the row's first settled frame after it mounted and every later
/// change under the same generation and physical mount is a post-mount resize,
/// which is what a remount regression (measuring or animating state re-derived
/// after admission) looks like from outside the row. An excluded frame
/// (streaming, entrance, replacement), a new generation or a new mount closes
/// the record, so the next settled frame starts a fresh baseline.
struct ChatHostedRowStabilityRecord: Sendable, Equatable {
    let semanticID: String
    let generation: Int?
    let mount: Int
    var firstHeight: CGFloat
    var latestHeight: CGFloat
    var resizeCount: Int
    var maximumResize: CGFloat
}

/// A row frame that arrived before its projection generation was installed.
/// The stability class travels with the frame so the deferred admission keeps
/// the same accounting the live path would have used.
private struct ChatHostedPendingRowFrame {
    let frame: CGRect
    let stability: ChatHostedRowStability
}

/// Reports the SwiftUI identity of the row content it is attached to. The
/// `@State` here is the identity under test: if an entrance admission or a
/// canonical handoff switched the subtree's structure, SwiftUI discards this
/// state and records a second instance for the same row.
struct ChatHostedRowIdentityProbe: View {
    let id: String
    let recorder: (any ChatTranscriptHostedRecording)?
    @State private var instance = UUID()

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .onAppear { recorder?.recordRowIdentity(id: id, instance: instance, isMount: true) }
            .onDisappear { recorder?.recordRowIdentity(id: id, instance: instance, isMount: false) }
    }
}

/// The hosted recorder a rendered row can reach, so a `HOSTED_TEST`-only
/// identity probe can live inside the row content that owns the structure under
/// test (the notification pill, for instance) without every product view taking
/// a recorder parameter.
struct ChatHostedRecorderBox: @unchecked Sendable {
    let recorder: (any ChatTranscriptHostedRecording)?
}

private struct ChatHostedRecorderKey: EnvironmentKey {
    static let defaultValue: ChatHostedRecorderBox? = nil
}

extension EnvironmentValues {
    var chatHostedRecorder: ChatHostedRecorderBox? {
        get { self[ChatHostedRecorderKey.self] }
        set { self[ChatHostedRecorderKey.self] = newValue }
    }
}

/// The compact thinking trace's own measurements. `contentHeight` is the
/// paragraph's measured height, `referenceHeight` the four reference lines', and
/// `overflowing` the flag the tap target, the mask and the accessibility trait
/// read.
struct ChatHostedThinkingTraceMeasurement: Equatable, Sendable {
    let contentHeight: CGFloat
    let referenceHeight: CGFloat
    let overflowing: Bool
}

/// One compact thinking trace's rendered motion per layout pass: the viewport the
/// layout gave it and the offset it placed the paragraph at. A streaming trace's
/// viewport and tail offset must interpolate together from one content height, so
/// both sequences step in animation frames instead of jumping a line per token.
struct ChatHostedThinkingTraceMotion: Equatable, Sendable {
    var viewportHeights: [CGFloat] = []
    var paragraphOffsets: [CGFloat] = []
}

/// One open thinking-trace detail sheet's own content: how many source characters
/// it is showing and where its scroll view sits. A sheet that follows the
/// transcript's installs grows with the trace and moves to its tail.
struct ChatHostedThinkingSheetSample: Equatable, Sendable {
    let sourceUTF16Length: Int
    let scrollOffset: CGFloat
}

/// A trace's measurements, so a hosted test can see that a mounted wrapped trace
/// measured itself and reads as overflowing: without them the rewrite would
/// silently lose the tap target and the tail fade.
struct ChatHostedThinkingTraceProbe: View {
    let id: String
    let contentHeight: CGFloat
    let referenceHeight: CGFloat
    let overflowing: Bool
    @Environment(\.chatHostedRecorder) private var hostedRecorder

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .onChange(of: measurement, initial: true) { _, value in
                hostedRecorder?.recorder?.recordThinkingTrace(
                    id: id,
                    contentHeight: value.contentHeight,
                    referenceHeight: value.referenceHeight,
                    overflowing: value.overflowing
                )
            }
    }

    private var measurement: Measurement {
        Measurement(
            contentHeight: contentHeight,
            referenceHeight: referenceHeight,
            overflowing: overflowing
        )
    }

    private struct Measurement: Equatable {
        let contentHeight: CGFloat
        let referenceHeight: CGFloat
        let overflowing: Bool
    }
}

struct ChatHostedScrollState: Sendable {
    let isDetached: Bool
    let hasUnread: Bool
    let isWaitingForPrependSemanticFrame: Bool
}

struct ChatHostedGeometryTraceSample: Sendable, Equatable {
    let frame: Int
    let offsetY: CGFloat
    /// The `LazyVStack` content estimate the coordinator reads as content
    /// height, and the container height it was published against. Both are part
    /// of the sample's identity by construction: a lazy stack re-derives the
    /// estimate when the container or inset changes, and can drop thousands of
    /// points under a held offset without moving the offset, the inset or a row
    /// frame — the transient a blank transcript is reported from.
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let composerHeight: CGFloat
    let rowFrames: [String: CGRect]
}

struct ChatHostedObservation: Sendable {
    let revision: Int
    let geometryTrace: [ChatHostedGeometryTraceSample]
    let geometry: ChatTranscriptGeometry
    let visibleRowIDs: [String]
    let rowFrames: [String: CGRect]
    /// Post-mount height evidence per settled row, and the rows whose frames
    /// were excluded because their own presentation owns their height.
    let rowStabilityRecords: [String: ChatHostedRowStabilityRecord]
    let excludedRowStabilityIDs: [String]
    /// Distinct row-content identities and mount counts per row. An entrance
    /// admission or a canonical handoff that switched a row's view structure
    /// shows up here as a second instance for the same row.
    let rowIdentityInstanceCounts: [String: Int]
    let rowIdentityMountCounts: [String: Int]
    /// The compact thinking traces' own measurements per trace identity.
    let thinkingTraceMeasurements: [String: ChatHostedThinkingTraceMeasurement]
    /// The compact thinking traces' rendered motion per trace identity: the
    /// viewport height and the paragraph offset, in the order the layout passes
    /// produced them.
    let thinkingTraceMotion: [String: ChatHostedThinkingTraceMotion]
    /// The prepared value each inline display card published for itself, keyed by
    /// its artifact identity. A value above the loader's retention ceiling is
    /// never retained, so the card that loaded it is the only place its render is
    /// observable at all.
    let inlineArtifactPublications: [String: Int]
    /// One open thinking-trace detail sheet's own content per trace identity, in
    /// the order its scroll geometry changed.
    let thinkingSheetSamples: [String: [ChatHostedThinkingSheetSample]]
    /// How many times each replacement host evaluated its body. A host that
    /// mirrors its row input evaluates a changed row twice (stale, then fresh);
    /// one that renders straight from `row` evaluates it once per update.
    let replacementHostEvaluations: [String: Int]
    let scrollSettledDistance: CGFloat?
    let scrollCommandCount: Int
    let targetReleaseCount: Int
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

    var postMountResizeCount: Int {
        rowStabilityRecords.values.reduce(0) { $0 + $1.resizeCount }
    }

    var maximumPostMountResize: CGFloat {
        rowStabilityRecords.values.map(\.maximumResize).max() ?? 0
    }

    var resizedSemanticIDs: [String] {
        rowStabilityRecords.values
            .filter { $0.resizeCount > 0 }
            .map(\.semanticID)
            .sorted()
    }

    /// Rows whose content identity changed more than once, which is a remount
    /// of a row that never left the installed projection.
    var remountedSemanticIDs: [String] {
        rowIdentityInstanceCounts.filter { $0.value > 1 }.keys.sorted()
    }

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
    private var rowFrames: [String: CGRect] = [:]
    private var rowFrameOrder: [String] = []
    private var rowFrameGeneration: Int?
    private var pendingRowFramesByGeneration: [Int: [String: ChatHostedPendingRowFrame]] = [:]
    private var rowStabilityRecords: [String: ChatHostedRowStabilityRecord] = [:]
    private var excludedRowStabilityIDs: Set<String> = []
    /// Physical mounts per row. A remount starts a new height baseline, because
    /// the row's first frame after it measures from scratch.
    private var rowMountCounters: [String: Int] = [:]
    private var rowIdentityInstances: [String: [UUID]] = [:]
    private var rowIdentityMountCounts: [String: Int] = [:]
    private var thinkingTraceMeasurements: [String: ChatHostedThinkingTraceMeasurement] = [:]
    private var thinkingTraceMotion: [String: ChatHostedThinkingTraceMotion] = [:]
    private var inlineArtifactPublications: [String: Int] = [:]
    private var thinkingSheetSamples: [String: [ChatHostedThinkingSheetSample]] = [:]
    private var replacementHostEvaluations: [String: Int] = [:]
    private var scrollSettledDistance: CGFloat?
    private var scrollCommandCount = 0
    private var targetReleaseCount = 0
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
    private(set) var composerCatalogBuildCount = 0
    private(set) var composerCatalogCommandNames: [String] = []
    var composerCatalogWillInstall: (@MainActor (ComposerResourceCatalog) async -> Void)?
    var composerCatalogDidFinish: (@MainActor ([CommandInfo]) -> Void)?
    var composerPickerEntries: (@MainActor () -> [ComposerResourceEntry])?
    var composerResourcePickerPresentation: (@MainActor (ChatAttachmentDestination?) -> Void)?
    var composerResourceSelection: (@MainActor (ComposerResourceEntry) -> Void)?
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
    private var displayControl: ((DisplayPresentationCommand) -> Void)?
    private var frameControl: (() async throws -> Void)?
    private var stateControl: (() -> ChatHostedScrollState)?
    private var prependControl: (() -> Bool)?
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
            geometry: geometry,
            visibleRowIDs: visibleRowIDs,
            rowFrames: rowFrames,
            rowStabilityRecords: rowStabilityRecords,
            excludedRowStabilityIDs: excludedRowStabilityIDs.sorted(),
            rowIdentityInstanceCounts: rowIdentityInstances.mapValues(\.count),
            rowIdentityMountCounts: rowIdentityMountCounts,
            thinkingTraceMeasurements: thinkingTraceMeasurements,
            thinkingTraceMotion: thinkingTraceMotion,
            inlineArtifactPublications: inlineArtifactPublications,
            thinkingSheetSamples: thinkingSheetSamples,
            replacementHostEvaluations: replacementHostEvaluations,
            scrollSettledDistance: scrollSettledDistance,
            scrollCommandCount: scrollCommandCount,
            targetReleaseCount: targetReleaseCount,
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
           previous.contentHeight == geometry.contentHeight,
           previous.containerHeight == geometry.containerHeight,
           previous.bottomInset == geometry.bottomInset,
           previous.composerHeight == composerHeight,
           previous.rowFrames == rowFrames {
            return
        }
        geometryTrace.append(ChatHostedGeometryTraceSample(
            frame: geometryTrace.last.map { $0.frame + 1 } ?? 0,
            offsetY: geometry.offsetY,
            contentHeight: geometry.contentHeight,
            containerHeight: geometry.containerHeight,
            bottomInset: geometry.bottomInset,
            composerHeight: composerHeight,
            rowFrames: rowFrames
        ))
        if geometryTrace.count > 240 {
            geometryTrace.removeFirst(geometryTrace.count - 240)
        }
    }

    func updateRowFrame(
        id: String,
        frame: CGRect,
        generation: Int? = nil,
        stability: ChatHostedRowStability = .notARow
    ) {
        if let generation {
            if let current = rowFrameGeneration {
                if generation < current { return }
                if generation > current {
                    bufferFutureRowFrame(id: id, frame: frame, generation: generation, stability: stability)
                    return
                }
            } else {
                bufferFutureRowFrame(id: id, frame: frame, generation: generation, stability: stability)
                return
            }
        }
        admitCurrentRowFrame(id: id, frame: frame, stability: stability)
    }

    private func bufferFutureRowFrame(
        id: String,
        frame: CGRect,
        generation: Int,
        stability: ChatHostedRowStability
    ) {
        var frames = pendingRowFramesByGeneration[generation, default: [:]]
        frames[id] = ChatHostedPendingRowFrame(frame: frame, stability: stability)
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
        generation: Int? = nil,
        recordsCallback: Bool = true,
        stability: ChatHostedRowStability = .notARow
    ) {
        if recordsCallback { semanticFrameCallbackCount &+= 1 }
        recordRowStability(id: id, frame: frame, generation: generation ?? rowFrameGeneration, stability: stability)
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

    /// The row-stability baseline is per mount: a settled frame starts it (or
    /// continues it while the installed generation and the physical mount are
    /// unchanged), an excluded frame closes it, and a frame whose height moved
    /// closes over one resize. Records are keyed by the semantic geometry
    /// identity, which is the physical row identity for every counted row kind
    /// (aliased prompt rows are excluded from counting).
    private func recordRowStability(
        id: String,
        frame: CGRect,
        generation: Int?,
        stability: ChatHostedRowStability
    ) {
        guard stability != .notARow, !id.isEmpty,
              frame.height.isFinite, frame.height >= 0 else { return }
        guard stability == .settled else {
            rowStabilityRecords[id] = nil
            if excludedRowStabilityIDs.count >= 256, !excludedRowStabilityIDs.contains(id) {
                excludedRowStabilityIDs.remove(excludedRowStabilityIDs.sorted().first ?? id)
            }
            excludedRowStabilityIDs.insert(id)
            return
        }
        let mount = rowMountCounters[id] ?? 0
        guard var record = rowStabilityRecords[id],
              record.generation == generation,
              record.mount == mount else {
            if rowStabilityRecords[id] == nil, rowStabilityRecords.count >= 256 {
                rowStabilityRecords.removeValue(forKey: rowStabilityRecords.keys.sorted().first ?? id)
            }
            rowStabilityRecords[id] = ChatHostedRowStabilityRecord(
                semanticID: id,
                generation: generation,
                mount: mount,
                firstHeight: frame.height,
                latestHeight: frame.height,
                resizeCount: 0,
                maximumResize: 0
            )
            return
        }
        let change = frame.height - record.latestHeight
        record.latestHeight = frame.height
        if abs(change) > 0.5 {
            record.resizeCount &+= 1
            record.maximumResize = max(record.maximumResize, abs(change))
        }
        rowStabilityRecords[id] = record
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

    func recordComposerCatalogBuild() {
        composerCatalogBuildCount &+= 1
        revision &+= 1
    }

    func recordComposerCatalogInstall(_ catalog: ComposerResourceCatalog) {
        composerCatalogCommandNames = catalog.commands.map(\.invocationName)
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
        if !id.isEmpty {
            if rowMountCounters[id] == nil, rowMountCounters.count >= 256,
               let retired = rowMountCounters.keys.sorted().first {
                rowMountCounters[retired] = nil
            }
            rowMountCounters[id, default: 0] &+= 1
        }
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

    func recordRowIdentity(id: String, instance: UUID, isMount: Bool) {
        guard !id.isEmpty else { return }
        var instances = rowIdentityInstances[id, default: []]
        if !instances.contains(instance) {
            if instances.count < 8 { instances.append(instance) }
        }
        rowIdentityInstances[id] = instances
        if isMount {
            if rowIdentityMountCounts[id] == nil, rowIdentityMountCounts.count >= 256,
               let retired = rowIdentityMountCounts.keys.sorted().first {
                rowIdentityMountCounts[retired] = nil
            }
            rowIdentityMountCounts[id, default: 0] &+= 1
        }
        revision &+= 1
    }

    /// A replacement host evaluation, recorded from the host's own body so a
    /// hosted test can count how many times a row update evaluated its content.
    func recordReplacementHostEvaluation(id: String) {
        guard !id.isEmpty else { return }
        Self.incrementBoundedCount(id: id, counts: &replacementHostEvaluations)
        revision &+= 1
    }

    /// The compact thinking trace's own measurements. A trace that never
    /// received them would keep its estimated viewport and lose its tap target
    /// and tail fade, so this is the rewrite's own oracle.
    func recordThinkingTrace(id: String, contentHeight: CGFloat, referenceHeight: CGFloat, overflowing: Bool) {
        guard !id.isEmpty else { return }
        let measurement = ChatHostedThinkingTraceMeasurement(
            contentHeight: contentHeight,
            referenceHeight: referenceHeight,
            overflowing: overflowing
        )
        guard thinkingTraceMeasurements[id] != measurement else { return }
        thinkingTraceMeasurements[id] = measurement
        revision &+= 1
    }

    /// One layout pass of a compact thinking trace. Consecutive equal values are
    /// dropped, so each sequence is the trace's own frame-to-frame motion.
    func recordThinkingTraceViewport(id: String, height: CGFloat) {
        guard !id.isEmpty, height.isFinite else { return }
        var motion = thinkingTraceMotion[id] ?? ChatHostedThinkingTraceMotion()
        guard motion.viewportHeights.last != height else { return }
        motion.viewportHeights.append(height)
        thinkingTraceMotion[id] = motion
        revision &+= 1
    }

    func recordThinkingTraceParagraphOffset(id: String, offset: CGFloat) {
        guard !id.isEmpty, offset.isFinite else { return }
        var motion = thinkingTraceMotion[id] ?? ChatHostedThinkingTraceMotion()
        guard motion.paragraphOffsets.last != offset else { return }
        motion.paragraphOffsets.append(offset)
        thinkingTraceMotion[id] = motion
        revision &+= 1
    }

    /// One inline display card's own prepared value. An artifact above the
    /// loader's retention ceiling is handed to the card instead of being retained,
    /// so this is the only record that the card renders what it loaded.
    func recordInlineArtifactPublication(id: String, bytes: Int) {
        guard !id.isEmpty, bytes > 0 else { return }
        guard inlineArtifactPublications[id] != bytes else { return }
        inlineArtifactPublications[id] = bytes
        revision &+= 1
    }

    /// One open thinking-trace sheet's content and scroll position.
    func recordThinkingSheet(id: String, sourceUTF16Length: Int, scrollOffset: CGFloat) {
        guard !id.isEmpty, scrollOffset.isFinite else { return }
        var samples = thinkingSheetSamples[id] ?? []
        let sample = ChatHostedThinkingSheetSample(
            sourceUTF16Length: sourceUTF16Length,
            scrollOffset: scrollOffset
        )
        guard samples.last != sample else { return }
        samples.append(sample)
        thinkingSheetSamples[id] = samples
        revision &+= 1
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
                for (id, pending) in pending {
                    admitCurrentRowFrame(
                        id: id,
                        frame: pending.frame,
                        recordsCallback: false,
                        stability: pending.stability
                    )
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
        presentDisplay: @escaping (DisplayPresentationCommand) -> Void,
        frame: @escaping () async throws -> Void,
        state: @escaping () -> ChatHostedScrollState,
        prepend: @escaping () -> Bool,
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
        displayControl = presentDisplay
        frameControl = frame
        stateControl = state
        prependControl = prepend
        invalidatePresentationControl = invalidatePresentation
        reopenPresentationControl = reopenPresentation
        cancelPresentationControl = cancelPresentation
        refreshControlledState()
    }

    func presentDisplay(_ command: DisplayPresentationCommand) { displayControl?(command) }

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

    func retirePresentation() {
        cancelPresentationControl?()
        refreshControlledState()
        cancelPrependPageWait()
        // Hosted controls capture the mounted view/probe. Final retirement
        // must break those cycles, not merely invoke their cancellation.
        geometryControl = nil
        phaseControl = nil
        nativeControl = nil
        catchUpControl = nil
        semanticResponseControl = nil
        submitPromptControl = nil
        importCameraImage = nil
        fixtureOpenPresentation = nil
        openingPhase = nil
        extensionPublicationAllowed = nil
        installedRuntime = nil
        displayControl = nil
        frameControl = nil
        stateControl = nil
        prependControl = nil
        invalidatePresentationControl = nil
        reopenPresentationControl = nil
        cancelPresentationControl = nil
        nextProjectionInstallControl = nil
        composerCatalogWillInstall = nil
        composerCatalogDidFinish = nil
        composerPickerEntries = nil
        composerResourcePickerPresentation = nil
        composerResourceSelection = nil
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

    var openingPhase: (() -> ChatOpenPresentationPhase)?
    var extensionPublicationAllowed: (() -> Bool)?
    var installedRuntime: (() -> String?)?
    private(set) var readyPublicationCount = 0
    var fixtureOpenPresentation: (() async throws -> Int)?
    var importCameraImage: ((UIImage) async -> Void)?

    func markReady() {
        readyPublicationCount += 1
        guard !isReady else { return }
        isReady = true
        revision &+= 1
    }
}
#endif
