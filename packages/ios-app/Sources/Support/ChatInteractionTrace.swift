import Foundation
import OSLog

/// Privacy-safe, bounded causal evidence for intermittent chat opening and
/// submission viewport failures. Records contain only closed event names,
/// booleans, counts, generations, and geometry scalars—never protocol IDs,
/// prompts, transcript text, paths, filenames, or model/provider names.
final class ChatInteractionTrace: @unchecked Sendable {
    static let maximumRecords = 256

    enum OpeningStage: String, Sendable {
        case attemptBegan = "attempt-began"
        case authorityOpened = "authority-opened"
        case projectionInstalled = "projection-installed"
        case baselineInstalled = "baseline-installed"
        case positioningBegan = "positioning-began"
        case positioningEnded = "positioning-ended"
        case revealBegan = "reveal-began"
        case readyFrame = "ready-frame"
        case failed
        case retired
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

    enum CommandStage: String, Sendable {
        case issued
        case applied
        case rejected
        case cleared
        case released
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

    enum Anomaly: String, Sendable {
        case submissionLostTail = "submission-lost-tail"
        case submissionLostProjection = "submission-lost-projection"
        case openingLostProjection = "opening-lost-projection"
        case openingViewportDisplaced = "opening-viewport-displaced"
    }

    struct State: Equatable, Sendable {
        var presentationEpoch: Int?
        var layoutEpoch: Int?
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
        var hasCommand: Bool?

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
        append(
            context: context,
            level: "info",
            event: "context.begin",
            details: "retained=\(Self.bit(retainedPresentation))"
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
            "token=\(command.token)",
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

    func diagnosticRecords(limit: Int) -> [GatewayProfileLogRecord] {
        guard limit > 0 else { return [] }
        lock.lock()
        let snapshot = Array(records.suffix(limit).reversed())
        lock.unlock()
        return snapshot.map { value in
            GatewayProfileLogRecord(
                profileID: "ios-client:chat-trace",
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
        if records.count > Self.maximumRecords {
            records.removeFirst(records.count - Self.maximumRecords)
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
        if let value = state.contentHeight { values.append("content=\(Self.scalar(value))") }
        if let value = state.containerHeight { values.append("container=\(Self.scalar(value))") }
        if let value = state.bottomInset { values.append("inset=\(Self.scalar(value))") }
        if let value = state.isPastBottomEdge { values.append("pastBottom=\(Self.bit(value))") }
        if let value = state.tailClassification { values.append("tail=\(Self.tail(value))") }
        if let value = state.tailDisplacement { values.append("tailDelta=\(Self.scalar(value))") }
        if let value = state.hasCommand { values.append("command=\(Self.bit(value))") }
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
        }
    }
    private static func destination(_ destination: ChatScrollCommand.Destination) -> String {
        switch destination {
        case .tail: "tail"
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
        case .morphFlight: "morph-flight"
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
    private var nextSubmissionToken = 0
    private(set) var activeSubmissionToken: Int?

    func installContext(_ context: Int) {
        self.context = context
    }

    func beginSubmission() -> Int {
        nextSubmissionToken &+= 1
        activeSubmissionToken = nextSubmissionToken
        return nextSubmissionToken
    }

    func ownsSubmission(_ token: Int) -> Bool {
        activeSubmissionToken == token
    }

    func endSubmission(_ token: Int) {
        guard activeSubmissionToken == token else { return }
        activeSubmissionToken = nil
    }

    func retire() {
        // Retain the ended context so late cancellation callbacks cannot create
        // a second owner after the view has disappeared.
        activeSubmissionToken = nil
    }
}
