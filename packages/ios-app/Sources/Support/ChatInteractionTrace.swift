import Foundation
import OSLog

/// Privacy-safe, bounded causal evidence for intermittent chat opening and
/// submission viewport failures. Records contain only closed event names,
/// booleans, counts, generations, and geometry scalars—never protocol IDs,
/// prompts, transcript text, paths, filenames, or model/provider names.
final class ChatInteractionTrace: @unchecked Sendable {
    static let maximumRecords = 256

    /// Profile identity these records carry in the Logs surface, so the
    /// diagnostic export can select exactly the trace it must always carry.
    static let diagnosticProfileID = "ios-client:chat-trace"

    enum OpeningStage: String, Sendable {
        case attemptBegan = "attempt-began"
        case authorityOpened = "authority-opened"
        case projectionInstalled = "projection-installed"
        case baselineInstalled = "baseline-installed"
        case positioningBegan = "positioning-began"
        case positioningEnded = "positioning-ended"
        case revealBegan = "reveal-began"
        case visibleRevealBegan = "visible-reveal-began"
        case readyFrameAwaited = "ready-frame-awaited"
        case readyFrame = "ready-frame"
        case failed
        case retired
    }

    enum OpeningFailureReason: String, Sendable {
        case authority = "authority-missing"
        case projection = "projection-missing"
        case commandApplication = "command-not-applied"
        case markerEpoch = "marker-epoch-stale"
        case viewport = "viewport-not-plausible"
        case viewportBoundary = "viewport-not-at-boundary"
        case physicalAlignment = "physical-tail-not-aligned"
        case frameStability = "frame-stability-incomplete"
        case presentationInactive = "presentation-inactive"
        case cancelled
        case replaced
        case unknown
    }

    enum ProjectionChange: String, Sendable {
        case first
        case sameSpine = "same-spine"
        case changedSpine = "changed-spine"
        case deferred
        case resumed
        case removed
    }

    enum SubmissionStage: String, Sendable {
        case began
        case lifecycleGrafted = "lifecycle-grafted"
        case projectionSubmitted = "projection-submitted"
        case transportSucceeded = "transport-succeeded"
        case transportFailed = "transport-failed"
        case admissionFailed = "admission-failed"
        case checkpoint
    }

    enum EntranceStage: String, Sendable {
        case admitted
        case admittedFallback = "admitted-fallback"
        case completed
    }

    enum CommandStage: String, Sendable {
        case issued
        case applied
        case rejected
        case cleared
        case released
    }

    enum LeaseStage: String, Sendable {
        case queued
        case releaseRequested = "release-requested"
        case releaseReady = "release-ready"
        case released
        case retargeted
        case canonicalHandoff = "canonical-handoff"
        case semanticHandoff = "semantic-handoff"
        case boundedFallback = "bounded-fallback"
        case repairExhausted = "repair-exhausted"
    }

    enum LeaseReason: String, Sendable {
        case targetOwned = "target-owned"
        case displacement
        case incompleteEvidence = "incomplete-evidence"
        case boundedFallback = "bounded-fallback"
        case settledEvidence = "settled-evidence"
        case frameBoundary = "frame-boundary"
        case consumed
        case canonicalAcknowledgement = "canonical-acknowledgement"
        case semanticIdentityChanged = "semantic-identity-changed"
        case attemptLimit = "attempt-limit"
    }

    enum LayoutStage: String, Sendable {
        case joined
        case participantSettled = "participant-settled"
        case settled
        case abandoned
        case overflow
    }

    enum GeometryReason: String, Sendable {
        case meaningfulChange = "meaningful-change"
        case submissionBaseline = "submission-baseline"
        case submissionCheckpoint = "submission-checkpoint"
        case openingCheckpoint = "opening-checkpoint"
    }

    enum TailEdgeStage: String, Sendable {
        case firstDisplacement = "first-displacement"
        case recovered
    }

    enum Anomaly: String, Sendable {
        case submissionLostTail = "submission-lost-tail"
        case submissionLostProjection = "submission-lost-projection"
        case openingLostProjection = "opening-lost-projection"
        case openingViewportDisplaced = "opening-viewport-displaced"
    }

    /// Closed, content-free inputs explain a disabled control without logging
    /// the command, draft, provider error, or canonical session identity.
    struct Availability: Equatable, Sendable {
        var connected: Bool
        var reconciling: Bool
        var mountedAuthority: Bool
        var projectionAvailable: Bool
        var openingTask: Bool
        var transcriptReady: Bool
        var scrollAllowsSubmission: Bool
        var scrollCommand: Bool
        var submissionPending: Bool
        var uploading: Bool
        var sending: Bool
        var commandReady: Bool
        var attachmentsReady: Bool
        var sceneActive: Bool
        var viewportActive: Bool
        var publicationActive: Bool
    }

    struct State: Equatable, Sendable {
        var presentationEpoch: Int?
        var layoutEpoch: Int?
        var observedLayoutEpoch: Int?
        var layoutGeneration: Int?
        var canonicalRows: Int?
        var runtimeRows: Int?
        var queueRows: Int?
        var hasLifecycleRow: Bool?
        var viewportMode: ChatViewportMode?
        var isUserInteracting: Bool?
        var isPositionedByUser: Bool?
        var distanceFromBottom: CGFloat?
        var offsetY: CGFloat?
        var contentHeight: CGFloat?
        var containerHeight: CGFloat?
        var bottomInset: CGFloat?
        var isPastBottomEdge: Bool?
        var tailClassification: ChatPhysicalTailClassification?
        var tailDisplacement: CGFloat?
        /// Pending command publication and an already-applied native target are
        /// separate leases and must never share one ambiguous diagnostic bit.
        var hasCommand: Bool?
        var hasAppliedTarget: Bool?
        var hasPendingRelease: Bool?
        var geometryRevision: Int?
        var semanticRevision: Int?
        var markerRevision: Int?
        var materializationRevision: Int?
        var repairAttempts: Int?
        var layoutSettled: Bool?
        /// Local bounded identity ordinals, not IDs or reversible hashes.
        var physicalRowToken: Int?
        var semanticRowToken: Int?
        var pendingPhysicalRowToken: Int?
        var pendingSemanticRowToken: Int?
        var pendingLayoutSettled: Bool?
        /// Signed physical row index relative to the installed terminal row;
        /// this is not a transcript ordinal or an identity token.
        var requestedRowOffsetFromTerminal: Int?
        var materializationRequiredRevision: Int?
        var nativeTailEvidence: Bool?
        var nativeRowEvidence: Bool?
        var nativeRowEvidenceFresh: Bool?
        var pendingRowEvidenceFresh: Bool?
        var rowMinY: CGFloat?
        var rowHeight: CGFloat?

        static let empty = State()
    }

    struct Record: Equatable, Sendable {
        let sequence: Int
        let context: Int
        let timestamp: String
        let level: String
        let event: String
        let message: String
    }

    private let lock = NSLock()
    private var nextSequence = 0
    private var nextContext = 0
    private var nextIdentity = 0
    private var identityTokens: [(id: String, token: Int)] = []
    private var lastRecordDate = Date.distantPast
    private var records: [Record] = []
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tron.mobile",
        category: "ChatInteractionTrace"
    )

    func beginContext(retainedPresentation: Bool) -> Int {
        lock.lock()
        nextContext &+= 1
        let context = nextContext
        lock.unlock()
        let version = Self.buildComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
        let build = Self.buildComponent(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion"))
        append(
            context: context,
            level: "info",
            event: "context.begin",
            details: "schema=2 app=\(version) build=\(build) retained=\(Self.bit(retainedPresentation))"
        )
        return context
    }

    func endContext(_ context: Int) {
        append(context: context, level: "info", event: "context.end", details: "")
    }

    func opening(
        _ stage: OpeningStage,
        context: Int,
        retainedPresentation: Bool? = nil,
        positioningSucceeded: Bool? = nil,
        state: State = .empty
    ) {
        var values: [String] = []
        if let retainedPresentation { values.append("retained=\(Self.bit(retainedPresentation))") }
        if let positioningSucceeded { values.append("positioned=\(Self.bit(positioningSucceeded))") }
        appendState(state, to: &values)
        append(
            context: context,
            level: stage == .failed ? "error" : "info",
            event: "opening.\(stage.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    func openingFailure(
        _ reasons: [OpeningFailureReason],
        context: Int,
        state: State
    ) {
        var values = ["reasons=\(reasons.map(\.rawValue).joined(separator: ","))"]
        appendState(state, to: &values)
        append(
            context: context,
            level: "error",
            event: "opening.failure-snapshot",
            details: values.joined(separator: " ")
        )
    }

    func availability(
        _ value: Availability,
        context: Int,
        blockedAction: Bool = false,
        state: State = .empty
    ) {
        let flags: [(String, Bool)] = [
            ("connected", value.connected), ("reconciling", value.reconciling),
            ("authority", value.mountedAuthority), ("projection", value.projectionAvailable),
            ("openingTask", value.openingTask), ("ready", value.transcriptReady),
            ("scrollAllowsSubmission", value.scrollAllowsSubmission), ("scrollCommand", value.scrollCommand),
            ("submissionPending", value.submissionPending), ("uploading", value.uploading),
            ("sending", value.sending), ("commandReady", value.commandReady),
            ("attachmentsReady", value.attachmentsReady), ("sceneActive", value.sceneActive),
            ("viewportActive", value.viewportActive), ("publicationActive", value.publicationActive)
        ]
        var values = flags.map { "\($0.0)=\(Self.bit($0.1))" }
        appendState(state, to: &values)
        append(
            context: context,
            level: "info",
            event: blockedAction ? "composer.admission-blocked" : "composer.availability",
            details: values.joined(separator: " ")
        )
    }

    func projection(
        _ change: ProjectionChange,
        context: Int,
        state: State
    ) {
        var values: [String] = []
        appendState(state, to: &values)
        append(
            context: context,
            level: change == .removed ? "warning" : "info",
            event: "projection.\(change.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    func submission(
        _ stage: SubmissionStage,
        context: Int,
        grafted: Bool? = nil,
        materialized: Bool? = nil,
        state: State = .empty
    ) {
        var values: [String] = []
        if let grafted { values.append("grafted=\(Self.bit(grafted))") }
        if let materialized { values.append("materialized=\(Self.bit(materialized))") }
        appendState(state, to: &values)
        let level = switch stage {
        case .transportFailed, .admissionFailed: "error"
        default: "info"
        }
        append(
            context: context,
            level: level,
            event: "submission.\(stage.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    func entrance(_ stage: EntranceStage, context: Int, state: State) {
        var values: [String] = []
        appendState(state, to: &values)
        append(context: context, level: "info", event: "entrance.\(stage.rawValue)", details: values.joined(separator: " "))
    }

    func viewportTransition(
        context: Int,
        from: ChatViewportMode,
        to: ChatViewportMode,
        intent: ChatViewportIntent,
        state: State
    ) {
        var values = [
            "from=\(Self.viewport(from))",
            "to=\(Self.viewport(to))",
            "intent=\(Self.intent(intent))"
        ]
        appendState(state, to: &values)
        append(
            context: context,
            level: "info",
            event: "viewport.transition",
            details: values.joined(separator: " ")
        )
    }

    func geometry(_ reason: GeometryReason, context: Int, state: State) {
        var values: [String] = []
        appendState(state, to: &values)
        append(
            context: context,
            level: "info",
            event: "geometry.\(reason.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    func command(
        _ stage: CommandStage,
        context: Int,
        command: ChatScrollCommand,
        state: State
    ) {
        var values = [
            "commandOrdinal=\(command.token)",
            "origin=\(Self.origin(command.origin))",
            "destination=\(Self.destination(command.destination))",
            "animated=\(Self.bit(command.animation != .disabled))"
        ]
        appendState(state, to: &values)
        append(
            context: context,
            level: "info",
            event: "command.\(stage.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    func lease(
        _ stage: LeaseStage,
        context: Int,
        token: Int?,
        reason: LeaseReason,
        state: State
    ) {
        var values = ["reason=\(reason.rawValue)"]
        if let token { values.append("commandOrdinal=\(token)") }
        appendState(state, to: &values)
        append(
            context: context,
            level: stage == .boundedFallback || stage == .repairExhausted ? "warning" : "info",
            event: "lease.\(stage.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    func layout(
        _ stage: LayoutStage,
        context: Int,
        generation: Int?,
        mutation: ChatLayoutMutation? = nil,
        joinedCount: Int? = nil,
        settledCount: Int? = nil
    ) {
        var values: [String] = []
        if let generation { values.append("generation=\(generation)") }
        if let mutation { values.append("mutation=\(Self.mutation(mutation))") }
        if let joinedCount { values.append("joined=\(joinedCount)") }
        if let settledCount { values.append("settled=\(settledCount)") }
        append(
            context: context,
            level: stage == .abandoned || stage == .overflow ? "warning" : "info",
            event: "layout.\(stage.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    func anomaly(_ anomaly: Anomaly, context: Int, state: State) {
        var values: [String] = []
        appendState(state, to: &values)
        append(
            context: context,
            level: "error",
            event: "anomaly.\(anomaly.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    /// Records classification edges from SwiftUI marker observations, not proof
    /// of a painted frame. The caller excludes user-owned scrolling; ordinary
    /// geometry stays thresholded while unexpected loss survives ring pressure.
    func tailEdge(
        _ stage: TailEdgeStage,
        context: Int,
        state: State,
        previousClassification: ChatPhysicalTailClassification?,
        previousTailDisplacement: CGFloat?,
        previousOffsetY: CGFloat?,
        previousContentHeight: CGFloat?
    ) {
        var values = ["beforeTail=\(previousClassification.map(Self.tail) ?? "unknown")"]
        if let value = previousTailDisplacement { values.append("beforeTailDelta=\(Self.scalar(value))") }
        if let value = previousOffsetY { values.append("beforeOffset=\(Self.scalar(value))") }
        if let value = previousContentHeight { values.append("beforeContent=\(Self.scalar(value))") }
        appendState(state, to: &values)
        append(
            context: context,
            level: stage == .firstDisplacement ? "warning" : "info",
            event: "tail.\(stage.rawValue)",
            details: values.joined(separator: " ")
        )
    }

    /// The pinned past-end safety net. No marker evidence and no repair budget
    /// are involved, so this record is the only evidence that an impossible
    /// pinned viewport was returned to the tail.
    func tailPastEndRepair(context: Int, distanceBeyondBottom: CGFloat?, state: State) {
        var values: [String] = []
        if let distanceBeyondBottom {
            values.append("pastEndBy=\(Self.scalar(distanceBeyondBottom))")
        }
        appendState(state, to: &values)
        append(
            context: context,
            level: "warning",
            event: "tail.past-end-repair",
            details: values.joined(separator: " ")
        )
    }

    func diagnosticRecords(limit: Int) -> [GatewayProfileLogRecord] {
        guard limit > 0 else { return [] }
        lock.lock()
        let snapshot = Array(records.suffix(limit).reversed())
        lock.unlock()
        return snapshot.map { value in
            GatewayProfileLogRecord(
                profileID: Self.diagnosticProfileID,
                profileLabel: "iOS client · Chat trace",
                record: GatewayLogRecord(
                    timestamp: value.timestamp,
                    level: value.level,
                    message: value.message,
                    event: value.event,
                    source: "ios-client"
                )
            )
        }
    }

    #if HOSTED_TEST
    func resetForTesting() {
        lock.lock()
        nextSequence = 0
        nextContext = 0
        nextIdentity = 0
        identityTokens = []
        lastRecordDate = .distantPast
        records = []
        lock.unlock()
    }
    #endif

    private func append(context: Int, level: String, event: String, details: String) {
        lock.lock()
        nextSequence &+= 1
        let sequence = nextSequence
        let message = details.isEmpty
            ? "context=\(context) sequence=\(sequence)"
            : "context=\(context) sequence=\(sequence) \(details)"
        let now = Date.now
        let recordDate = max(now, lastRecordDate.addingTimeInterval(0.001))
        lastRecordDate = recordDate
        let record = Record(
            sequence: sequence,
            context: context,
            timestamp: timestampFormatter.string(from: recordDate),
            level: level,
            event: "chat.\(event)",
            message: message
        )
        records.append(record)
        while records.count > Self.maximumRecords {
            // Evict repetitive samples before causal lifecycle edges. Keep
            // context starts, commands, failures, and warnings long enough to
            // interpret the bounded suffix without retaining private content.
            let evictionIndex = records.firstIndex {
                $0.level == "info" && (
                    $0.event.hasPrefix("chat.geometry.")
                        || $0.event == "chat.viewport.transition"
                        || $0.event == "chat.submission.checkpoint"
                )
            } ?? records.firstIndex {
                $0.level == "info" && $0.event != "chat.context.begin"
            } ?? records.firstIndex {
                $0.level == "info"
            } ?? records.startIndex
            records.remove(at: evictionIndex)
        }
        lock.unlock()
        switch level {
        case "error":
            logger.error("\(record.event, privacy: .public) \(record.message, privacy: .public)")
        case "warning":
            logger.warning("\(record.event, privacy: .public) \(record.message, privacy: .public)")
        default:
            logger.info("\(record.event, privacy: .public) \(record.message, privacy: .public)")
        }
    }

    private func appendState(_ state: State, to values: inout [String]) {
        if let value = state.presentationEpoch { values.append("presentation=\(value)") }
        if let value = state.layoutEpoch { values.append("layout=\(value)") }
        if let value = state.observedLayoutEpoch { values.append("observedLayout=\(value)") }
        if let value = state.layoutGeneration { values.append("layoutGeneration=\(value)") }
        if let value = state.canonicalRows { values.append("canonicalRows=\(value)") }
        if let value = state.runtimeRows { values.append("runtimeRows=\(value)") }
        if let value = state.queueRows { values.append("queueRows=\(value)") }
        if let value = state.hasLifecycleRow { values.append("lifecycle=\(Self.bit(value))") }
        if let value = state.viewportMode { values.append("mode=\(Self.viewport(value))") }
        if let value = state.isUserInteracting { values.append("interacting=\(Self.bit(value))") }
        if let value = state.isPositionedByUser { values.append("userPosition=\(Self.bit(value))") }
        if let value = state.distanceFromBottom { values.append("bottom=\(Self.scalar(value))") }
        if let value = state.offsetY { values.append("offset=\(Self.scalar(value))") }
        if let value = state.contentHeight {
            values.append("content=\(Self.scalar(value))")
            values.append("geometrySource=swiftui-estimate")
        }
        if let value = state.containerHeight { values.append("container=\(Self.scalar(value))") }
        if let value = state.bottomInset { values.append("inset=\(Self.scalar(value))") }
        if let value = state.isPastBottomEdge { values.append("pastBottom=\(Self.bit(value))") }
        if let value = state.tailClassification { values.append("tail=\(Self.tail(value))") }
        if let value = state.tailDisplacement { values.append("tailDelta=\(Self.scalar(value))") }
        if let value = state.hasCommand { values.append("command=\(Self.bit(value))") }
        if let value = state.hasAppliedTarget { values.append("target=\(Self.bit(value))") }
        if let value = state.hasPendingRelease { values.append("release=\(Self.bit(value))") }
        if let value = state.geometryRevision { values.append("geometryRev=\(value)") }
        if let value = state.semanticRevision { values.append("semanticRev=\(value)") }
        if let value = state.markerRevision { values.append("markerRev=\(value)") }
        if let value = state.materializationRevision { values.append("materializationRev=\(value)") }
        if let value = state.repairAttempts { values.append("repairs=\(value)") }
        if let value = state.layoutSettled { values.append("layoutSettled=\(Self.bit(value))") }
        if let value = state.physicalRowToken { values.append("physicalRow=\(value)") }
        if let value = state.semanticRowToken { values.append("semanticRow=\(value)") }
        if let value = state.pendingPhysicalRowToken { values.append("pendingPhysicalRow=\(value)") }
        if let value = state.pendingSemanticRowToken { values.append("pendingSemanticRow=\(value)") }
        if let value = state.pendingLayoutSettled { values.append("pendingLayoutSettled=\(Self.bit(value))") }
        if let value = state.requestedRowOffsetFromTerminal { values.append("requestedFromTerminal=\(value)") }
        if let value = state.materializationRequiredRevision { values.append("materializationRequiredRev=\(value)") }
        if let value = state.nativeTailEvidence { values.append("tailEvidence=\(value ? "swiftui-marker" : "missing")") }
        if let value = state.nativeRowEvidence { values.append("rowEvidence=\(value ? "swiftui-frame" : "missing")") }
        if let value = state.nativeRowEvidenceFresh { values.append("rowEvidenceFresh=\(Self.bit(value))") }
        if let value = state.pendingRowEvidenceFresh { values.append("pendingRowEvidenceFresh=\(Self.bit(value))") }
        if let value = state.rowMinY { values.append("rowY=\(Self.scalar(value))") }
        if let value = state.rowHeight { values.append("rowHeight=\(Self.scalar(value))") }
    }

    /// At most 64 short identities are retained in memory, never exported.
    /// Evicted identities get new ordinals rather than false continuity. Cost
    /// does not scale with transcript history or streamed text.
    func identityToken(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.utf8.prefix(257).count <= 256 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let index = identityTokens.firstIndex(where: { $0.id == value }) {
            let entry = identityTokens.remove(at: index)
            identityTokens.append(entry)
            return entry.token
        }
        nextIdentity &+= 1
        if identityTokens.count == 64 { identityTokens.removeFirst() }
        identityTokens.append((value, nextIdentity))
        return nextIdentity
    }

    private static func buildComponent(_ value: Any?) -> String {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return "unknown" }
        return value
    }

    private static func bit(_ value: Bool) -> Int { value ? 1 : 0 }
    private static func scalar(_ value: CGFloat) -> String {
        guard value.isFinite else { return "nonfinite" }
        return String(format: "%.1f", Double(value))
    }
    private static func viewport(_ mode: ChatViewportMode) -> String {
        switch mode { case .pinned: "pinned"; case .anchored: "anchored" }
    }
    private static func intent(_ intent: ChatViewportIntent) -> String {
        switch intent {
        case .userTookOver: "user-took-over"
        case .userReturnedToTail: "user-returned-to-tail"
        case .catchUpRequested: "catch-up"
        case .submitted: "submitted"
        case .opened: "opened"
        case .prependBegan: "prepend-began"
        case .prependEnded: "prepend-ended"
        case .presentationReset(let retained): "presentation-reset-retained-\(bit(retained))"
        }
    }
    private static func origin(_ origin: ChatScrollCommand.Origin) -> String {
        switch origin {
        case .presentation: "presentation"
        case .catchUp: "catch-up"
        case .layout: "layout"
        case .prepend: "prepend"
        case .tailMaterialization: "tail-materialization"
        case .physicalTailRepair: "physical-tail-repair"
        case .pastEndRepair: "past-end-repair"
        }
    }
    private static func destination(_ destination: ChatScrollCommand.Destination) -> String {
        switch destination {
        case .tail: "tail"
        case .materialize: "materialize"
        case .openingTail: "opening-tail"
        case .offsetY: "offset"
        }
    }
    private static func tail(_ classification: ChatPhysicalTailClassification) -> String {
        switch classification {
        case .aligned: "aligned"
        case .belowViewport: "below-viewport"
        case .aboveViewport: "above-viewport"
        case .incomplete: "incomplete"
        case .stale: "stale"
        }
    }
    private static func mutation(_ mutation: ChatLayoutMutation) -> String {
        switch mutation {
        case .keyboard: "keyboard"
        case .submission: "submission"
        case .transcriptGrowth: "transcript-growth"
        }
    }
}

enum ChatInteractionAnomalyPolicy {
    static func lostProjection(expectedRows: Int, currentRows: Int) -> Bool {
        expectedRows > 0 && currentRows == 0
    }

    static func displacedPinnedViewport(
        expectedPinned: Bool,
        currentMode: ChatViewportMode,
        isUserInteracting: Bool,
        isPositionedByUser: Bool,
        geometry: ChatTranscriptGeometry,
        tailClassification: ChatPhysicalTailClassification?
    ) -> Bool {
        guard expectedPinned,
              currentMode == .pinned,
              !isUserInteracting,
              !isPositionedByUser,
              geometry.isValid else { return false }
        let markerIsDisplaced = tailClassification == .aboveViewport
            || tailClassification == .belowViewport
        // A short/empty transcript intentionally fills only the viewport above
        // the composer inset. Its marker can differ by that exact inset while
        // native bottom geometry remains correctly installed.
        if geometry.isNativeUnderflow,
           geometry.isAtCatchUpBoundary,
           !geometry.isPastBottomEdge {
            return false
        }
        return markerIsDisplaced
            || geometry.isPastBottomEdge
            || geometry.distanceFromBottom > max(160, geometry.containerHeight * 0.65)
    }
}

/// Non-observable per-view bookkeeping keeps tracing from invalidating the
/// transcript or participating in the layout race it is observing.
@MainActor
final class ChatInteractionTraceLedger {
    private(set) var context: Int?
    private var isActive = false
    private var nextSubmissionToken = 0
    private(set) var activeSubmissionToken: Int?

    func installContext(_ context: Int) {
        self.context = context
        isActive = true
    }

    func ownsContext(_ context: Int) -> Bool { isActive && self.context == context }

    func beginSubmission() -> Int {
        nextSubmissionToken &+= 1
        activeSubmissionToken = nextSubmissionToken
        return nextSubmissionToken
    }

    func ownsSubmission(_ token: Int) -> Bool {
        isActive && activeSubmissionToken == token
    }

    func endSubmission(_ token: Int) {
        guard activeSubmissionToken == token else { return }
        activeSubmissionToken = nil
    }

    func retire() {
        // Retain the ended context so late cancellation callbacks cannot create
        // a second owner after the view has disappeared.
        isActive = false
        activeSubmissionToken = nil
    }
}
