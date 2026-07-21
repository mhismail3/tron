import SwiftUI
import PhotosUI
import UIKit

// MARK: - Chat View Model

@Observable
@MainActor
final class ChatViewModel {

    // MARK: - Observable State

    var messages: [ChatMessage] = []
    /// Agent lifecycle phase for the primitive chat loop.
    var agentPhase: AgentPhase = .idle
    var isProcessing: Bool { agentPhase.isProcessing }
    /// Compaction is in progress (LLM summarizer call running).
    /// While true: send button disabled, spinning compaction pill shown.
    /// Orthogonal to `agentPhase`: compaction can run during any phase (including idle)
    /// because context maintenance can trigger it asynchronously. A turn_start resets it.
    var isCompacting = false
    var showSettings = false
    /// Set to true when the session doesn't exist on server and view should navigate back
    var shouldDismiss = false
    var isThinkingExpanded = false
    /// Whether more older messages are available for loading
    var hasMoreMessages = false
    /// Whether currently loading more messages
    var isLoadingMoreMessages = false
    // MARK: - Input State (delegated to InputBarState)

    /// Text input - delegated to inputBarState
    var inputText: String {
        get { inputBarState.text }
        set { inputBarState.text = newValue }
    }

    /// Selected images from photo picker - delegated to inputBarState
    var selectedImages: [PhotosPickerItem] {
        get { inputBarState.selectedImages }
        set { inputBarState.selectedImages = newValue }
    }

    /// Attachments for the current message - delegated to inputBarState
    var attachments: [Attachment] {
        get { inputBarState.attachments }
        set { inputBarState.attachments = newValue }
    }

    // MARK: - Extracted State Objects

    /// Context tracking state (tokens, cost, context window)
    let contextState = ContextTrackingState()
    /// Thinking state (for extended thinking display)
    let thinkingState = ThinkingState()
    /// Input bar state (text, attachments, reasoning level)
    let inputBarState = InputBarState()
    /// Model picker state (cached models, optimistic updates, switching)
    let modelPickerState: ModelPickerState
    // MARK: - Protocol Conformance (Context Protocols)

    /// Make a capability visible for rendering (CapabilityInvocationContext)
    func makeCapabilityInvocationVisible(_ invocationId: String) {
        animationCoordinator.makeCapabilityInvocationVisible(invocationId)
    }

    /// Logging methods (ChatCoordinatorContext)
    func logVerbose(_ message: String) {
        logger.verbose(message, category: .events)
    }

    func logDebug(_ message: String) {
        logger.debug(message, category: .events)
    }

    func logInfo(_ message: String) {
        logger.info(message, category: .events)
    }

    func logWarning(_ message: String) {
        logger.warning(message, category: .events)
    }

    func logError(_ message: String) {
        logger.error(message, category: .events)
    }

    /// Show error to user (required by ChatCoordinatorContext).
    func showError(_ message: String) {
        handleError(message, severity: .fatal)
    }

    // MARK: - Internal State (accessible to extensions)

    let services: ChatSessionServices
    let sessionId: String
    /// PhotosPicker I/O adapter. The selection task captures this value rather
    /// than retaining the mounted view model across an external data load.
    @ObservationIgnored
    let photoPickerDataLoader: PhotoPickerDataLoader
    /// Task for handling the live session event stream.
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private var eventTaskGeneration: UInt64 = 0
    /// ID of the thinking message for the current turn (thinking appears before text response)
    var thinkingMessageId: UUID?
    /// True while reconstruction is in progress — buffers real-time events for replay after
    var isReconstructing = false
    /// Events buffered during reconstruction. They drain only after a server
    /// snapshot commits its sequence high-water mark and projection.
    @ObservationIgnored
    var eventBuffer: [ParsedEventV2] = []
    /// Highest processed event sequence number. Events with seq <= this are dropped (dedup).
    var sequenceHighWaterMark: Int64 = -1
    /// Monotonic request observed by the mounted ChatView. The view owns the
    /// cancel-and-replace reconstruction task; the event handler owns no Task.
    private(set) var streamRecoveryRequestGeneration: UInt64 = 0

    func advanceStreamRecoveryRequest() {
        streamRecoveryRequestGeneration &+= 1
    }
    /// Oldest event ID from the loaded reconstruction window (for pagination cursor).
    var reconstructionOldestEventId: String?
    /// Whether the server reported older reconstruction pages before `reconstructionOldestEventId`.
    var hasOlderServerReconstructionPages = false
    /// Raw reconstruction events already loaded into the timeline window.
    ///
    /// Older pages are transformed with this newer context so an assistant
    /// content block split from its capability completion still renders the
    /// completed chip instead of degrading to a running placeholder.
    @ObservationIgnored
    var loadedReconstructionEvents: [RawEvent] = []
    /// Snapshot of the live streaming message captured in
    /// `cleanUpStreamingState` so reconstruction can reuse its UUID
    /// when the in-flight streaming text continues from the same point.
    /// Eliminates the flicker of the streaming bubble disappearing and
    /// reappearing with a different identity across a transient
    /// disconnect. Consumed in `processInFlightState`; any uncovered
    /// snapshot is logged at the end of `processReconstructionResult`
    /// as a defensive data-loss-detection signal (should be impossible
    /// with persist-before-broadcast, but guarded regardless).
    @ObservationIgnored
    var streamingRecoverySnapshot: StreamingRecoverySnapshot?
    /// ID of the compaction-in-progress notification (replaced when compaction completes)
    var compactionInProgressMessageId: UUID?
    /// Temporary local notifications belong to the mounted chat UI only.
    var localNotificationIdsByDedupKey: [String: UUID] = [:]
    // MARK: - Coordinators

    /// Coordinates pill morph animations, message cascade timing, and capability staggering
    let animationCoordinator = AnimationCoordinator()
    /// Ensures capability invocations appear in order and batches UI updates for 60fps
    let uiUpdateQueue = UIUpdateQueue()
    /// Manages text delta batching, thinking content, and backpressure
    let streamingManager = StreamingManager()
    /// Coordinates capability invocation event handling (start/end) for capability invocation messages and UI updates
    let capabilityInvocationCoordinator = CapabilityInvocationCoordinator()
    /// Coordinates turn lifecycle handling (start/end, complete)
    let turnLifecycleCoordinator = TurnLifecycleCoordinator()
    /// Coordinates message sending, abort, and attachments
    let messagingCoordinator = MessagingCoordinator()
    /// Coordinates session connection, reconnection, and catch-up
    let connectionCoordinator = ConnectionCoordinator()
    /// Coordinates compaction event handling (start/complete pill transitions)
    let compactionCoordinator = CompactionCoordinator()
    /// O(1) message lookup index — kept in sync with `messages` array
    let messageIndex = MessageIndex()
    /// Message identities for capability invocations in the live current turn.
    var currentTurnCapabilityMessageIds: Set<UUID> = []

    /// Track the message index where the current turn started
    /// Used to find which messages to update with metadata at turn_end
    var turnStartMessageIndex: Int?

    /// Track the first text message ID of the current turn
    /// This message gets the token/model/latency metadata at turn_end
    var firstTextMessageIdForTurn: UUID?

    // MARK: - Performance Optimization: Batched Updates
    // Note: Batching state moved to StreamingManager which uses CADisplayLink for efficient updates

    // MARK: - Event Store Reference

    /// Reference to EventStoreManager for event-sourced persistence
    weak var eventStoreManager: EventStoreManager?

    /// Reference to DraftStore for persisting unsent input state
    weak var draftStore: DraftStore?

    /// Workspace ID for event caching
    var workspaceId: String = ""

    /// Current turn counter
    var currentTurn = 0

    // MARK: - Pagination State

    /// All loaded messages from EventDatabase (full set for pagination)
    var allReconstructedMessages: [ChatMessage] = []
    /// Number of messages to show initially.
    /// Keep this large enough that long restored sessions open with useful
    /// recent context while still letting the timeline lazily page older rows.
    static let initialMessageBatchSize = 300
    /// Initial persisted event count requested from `session::reconstruct`.
    static let initialReconstructionEventLimit = 300
    /// Upper bound for a single reconnect reconstruction request. Larger gaps
    /// are filled by bounded pagination in `processReconstructionResult`.
    static let maxReconstructionEventLimit = 1_000
    /// Maximum older pages fetched to close a reconnect history gap.
    static let maxReconstructionGapBackfillPages = 20
    /// Number of older messages to prepend per top-detent pass.
    /// Keep this smaller than the initial bottom slice: older-history rows can
    /// contain large markdown and many tool chips, and prepending them happens
    /// while preserving an active reading viewport.
    static let additionalMessageBatchSize = 90
    /// Prune when messages exceed this count during live sessions
    static let liveSessionPruneThreshold = 200
    /// Keep this many messages after pruning
    static let liveSessionPruneTarget = 100
    /// Max pruned messages to buffer (beyond this, oldest discarded to DB-only recovery)
    static let maxPrunedBufferSize = 500
    /// Current number of messages displayed (from the end)
    var displayedMessageCount = 0
    /// Whether initial history has been loaded (prevents redundant loads on view re-entry)
    var hasInitiallyLoaded = false

    /// Messages pruned from display during live sessions. NOT tracked by SwiftUI.
    /// Used for instant earlier-history recovery without DB reconstruction.
    @ObservationIgnored
    var prunedLiveMessages: [ChatMessage] = []

    /// Incremented after each prune — view observes this to anchor scroll position.
    var prunedVersion: Int = 0

    // MARK: - Initialization

    init(
        services: ChatSessionServices,
        sessionId: String,
        eventStoreManager: EventStoreManager? = nil,
        photoPickerDataLoader: PhotoPickerDataLoader = .live
    ) {
        self.services = services
        self.sessionId = sessionId
        self.eventStoreManager = eventStoreManager
        self.photoPickerDataLoader = photoPickerDataLoader
        self.modelPickerState = ModelPickerState(modelRepository: services.models)
        setupBindings()
        setupEventProcessingCallbacks()
    }

    @ObservationIgnored
    private var observationTasks: [Task<Void, Never>] = []

    private func setupBindings() {
        let connection = services.connection
        let inputBarState = inputBarState

        observationTasks.append(Self.observeLoop({ connection.connectionState }) { [weak self] state in
            guard let self else { return }

            if case .disconnected = state {
                // A matched Stop remains pending across transport loss. Only
                // canonical terminal events or reconstruction can decide its
                // outcome; clearing it here would re-enable duplicate Stop.
                if agentPhase == .processing {
                    agentPhase = .idle
                }
                isCompacting = false
                compactionInProgressMessageId = nil
                runningCapabilityInvocationCount = 0
                prunedLiveMessages.removeAll()
            }
        })

        observationTasks.append(Self.observeLoop({ inputBarState.selectedImages }) { [weak self] images in
            self?.startSelectedImageProcessing(images)
        })

    }

    func startLiveEventStream() {
        // Subscribe to plugin-based event stream using the session event repository.
        // Filter to only handle events for this session
        guard eventTask == nil else { return }
        eventTaskGeneration += 1
        let generation = eventTaskGeneration
        let eventRepository = services.events
        let sessionId = self.sessionId
        eventTask = Task { [weak self] in
            logger.info("[LIVE] Starting engine event stream for session \(sessionId)", category: .events)
            for await event in eventRepository.events(for: sessionId) {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                logger.verbose(
                    "[LIVE] ChatViewModel received event \(event.eventType) session=\(event.sessionId ?? "nil") seq=\(event.sequence?.description ?? "nil")",
                    category: .events
                )
                handleEventV2(event)
            }
            logger.info("[LIVE] Engine event stream ended for session \(sessionId), cancelled=\(Task.isCancelled)", category: .events)
            guard let self else { return }
            if self.eventTaskGeneration == generation {
                self.eventTask = nil
            }
        }
    }

    func stopLiveEventStream() {
        eventTaskGeneration += 1
        eventTask?.cancel()
        eventTask = nil
    }

    /// Single cancel-and-replace owner for the current PhotosPicker selection.
    @ObservationIgnored
    var selectedImageTask: Task<Void, Never>?

    deinit {
        // MainActor classes always deinit on the main actor.
        // assumeIsolated lets the compiler see we can safely access isolated state.
        MainActor.assumeIsolated {
            eventTask?.cancel()
            for task in observationTasks { task.cancel() }
            selectedImageTask?.cancel()
        }
    }

    /// Unified event handler - buffers during reconstruction, dispatches otherwise
    func handleEventV2(_ event: ParsedEventV2) {
        if isReconstructing {
            if eventBuffer.count < 3 {
                // Log first few buffered events for debugging
                logger.debug("[RECONSTRUCT] Buffering event during reconstruction: \(event.eventType) (buffer=\(eventBuffer.count + 1))", category: .events)
            }
            eventBuffer.append(event)
            return
        }
        logger.verbose(
            "[LIVE] Dispatching event \(event.eventType) seq=\(event.sequence?.description ?? "nil") watermark=\(sequenceHighWaterMark)",
            category: .events
        )
        dispatchEvent(event)
    }

    /// Dispatch a single event to the appropriate handler.
    ///
    /// Sequence filter: if the event carries a per-session event-log
    /// sequence, drop it when `sequence <= sequenceHighWaterMark` so an
    /// already-processed event (from a late reconnect, a buffered replay,
    /// or a reordered broadcast) does not get dispatched twice.
    /// Events without a sequence bypass the filter — they are either
    /// unpersisted lifecycle signals or the `.unknown` placeholder.
    func dispatchEvent(_ event: ParsedEventV2) {
        if let seq = event.sequence, seq <= sequenceHighWaterMark {
            logger.debug(
                "[DEDUP] dropping \(event.eventType) seq=\(seq) <= watermark=\(sequenceHighWaterMark)",
                category: .events
            )
            return
        }

        switch event {
        case .plugin(let type, _, _, _, let transform):
            handlePluginEvent(type: type, transform: transform)
        case .unknown(let type):
            logger.debug("Unknown event type: \(type)", category: .events)
        }

        // Advance the watermark AFTER successful dispatch so a failure in
        // handlePluginEvent doesn't prematurely skip a retry.
        if let seq = event.sequence, seq > sequenceHighWaterMark {
            sequenceHighWaterMark = seq
        }
    }

    /// Handle a plugin-based event through the authoritative registry.
    private func handlePluginEvent(type: String, transform: @Sendable () -> (any EventResult)?) {
        EventRegistry.shared.dispatch(type: type, transform: transform, context: self)
    }

    // MARK: - Message Updates

    func finalizeStreamingMessage() {
        // Use StreamingManager for finalization (clears streamingMessageId and streamingText)
        _ = streamingManager.finalizeStreamingMessage()
    }

    /// Mark the current thinking message as no longer streaming (if present)
    func markThinkingMessageCompleteIfNeeded() {
        guard let id = thinkingMessageId,
              let index = messageIndex.index(for: id),
              case .thinking(let visible, let isExpanded, let isStreaming, let kind) = messages[index].content,
              isStreaming else {
            return
        }

        updateMessage(at: index) { message in
            message.content = .thinking(
                visible: visible,
                isExpanded: isExpanded,
                isStreaming: false,
                kind: kind
            )
        }
        thinkingState.markStreamingComplete()
    }

    /// Force flush any pending text updates (called before completion)
    func flushPendingTextUpdates() {
        // Delegate to StreamingManager for flushing
        streamingManager.flushPendingText()
    }

    // MARK: - Commands

    /// Add an in-chat notification when model is switched
    func addModelChangeNotification(from previousModel: String, to newModel: String) {
        let notification = ChatMessage.modelChange(
            from: previousModel.shortModelName,
            to: newModel.shortModelName
        )
        appendToMessages(notification)
        logger.info("Model switched from \(previousModel) to \(newModel)", category: .session)
    }

    /// Add an in-chat notification when reasoning level is changed
    func addReasoningLevelChangeNotification(from previousLevel: String, to newLevel: String) {
        let notification = ChatMessage.reasoningLevelChange(
            from: previousLevel.capitalized,
            to: newLevel.capitalized
        )
        appendToMessages(notification)
        logger.info("Reasoning level changed from \(previousLevel) to \(newLevel)", category: .session)
    }

    // MARK: - Message Operations

    /// Delete a message from the session.
    /// This sends an engine request to append a message.deleted event.
    /// The message will be filtered out during two-pass reconstruction.
    func deleteMessage(_ message: ChatMessage) async {
        guard let sessionId = services.events.currentSessionId else {
            appendLocalError(dedupKey: "message.delete.no-session", title: "Could not delete message", message: "No active session.")
            return
        }

        guard let eventId = message.eventId else {
            appendLocalError(dedupKey: "message.delete.missing-event", title: "Could not delete message", message: "This message is not backed by a deletable server event.")
            return
        }

        // Only allow deleting user and assistant messages
        guard message.role == .user || message.role == .assistant else {
            appendLocalError(dedupKey: "message.delete.invalid-role", title: "Could not delete message", message: "This message type cannot be deleted.")
            return
        }

        logger.info("Deleting message: eventId=\(eventId)", category: .session)

        do {
            let result = try await services.messages.deleteMessage(
                sessionId: sessionId,
                targetEventId: eventId,
                idempotencyKey: .userAction("message.delete")
            )
            logger.info("Message deleted successfully: deletionEventId=\(result.deletionEventId)", category: .session)

            // Remove the message from local state immediately for responsive UI
            // The server will also send an event.new notification which we handle in Events extension
            await MainActor.run {
                if let index = MessageFinder.indexByEventId(eventId, in: self.messages) {
                    self.removeFromMessages(at: index)
                }
            }
        } catch {
            appendLocalError(dedupKey: "message.delete.failed", title: "Could not delete message", message: error.localizedDescription)
        }
    }

    // MARK: - Computed Properties

    var shouldShowProcessingIndicator: Bool {
        agentPhase != .idle
    }

    /// Show "Processing..." only when the model is thinking and no other
    /// visual feedback is active (streaming text, thinking block, or capability
    /// spinner).
    ///
    /// Every property read here must be on an @Observable object so SwiftUI
    /// re-evaluates when state changes. StreamingManager is NOT @Observable,
    /// so we check `messages` (which is tracked) instead.
    var shouldShowBreathingLine: Bool {
        guard agentPhase == .processing else { return false }
        if messages.last?.isStreaming == true { return false }
        if isThinkingActivelyStreaming { return false }
        if hasRunningCapabilityInvocations { return false }
        return true
    }

    private var isThinkingActivelyStreaming: Bool {
        guard let id = thinkingMessageId,
              let index = messageIndex.index(for: id),
              case .thinking(_, _, let isStreaming, _) = messages[index].content else {
            return false
        }
        return isStreaming
    }

    /// Counter-based running capability detection — O(1) instead of O(n*m) scan.
    /// Incremented in capability start handler, decremented in processOrderedCapabilityInvocationCompleted and capability end handler.
    /// Reset on turn start and disconnect.
    var runningCapabilityInvocationCount: Int = 0

    private var hasRunningCapabilityInvocations: Bool {
        runningCapabilityInvocationCount > 0
    }

    var currentModel: String {
        services.events.currentModel
    }

    var hasActiveSession: Bool {
        services.events.hasActiveSession
    }

    /// Updates the context window from the model catalog loaded by ChatView.
    func updateContextWindow(from models: [ModelInfo]) {
        if let model = models.first(where: { $0.id == currentModel }) {
            contextState.currentContextWindow = model.contextWindow
        }
    }

    // Note: Deep link methods moved to ChatViewModel+DeepLinks.swift
}
