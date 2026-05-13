import SwiftUI
import PhotosUI
import UIKit

// MARK: - Chat View Model
// Note: CapabilityInvocationRecord is defined in EventStoreManager.swift

@Observable
@MainActor
final class ChatViewModel {

    // MARK: - Observable State

    var messages: [ChatMessage] = []
    /// Agent lifecycle phase (idle → processing → postProcessing → idle).
    /// Replaces the previous `isProcessing` / `isPostProcessing` booleans
    /// which could get into invalid states (both true simultaneously).
    var agentPhase: AgentPhase = .idle
    /// Compaction is in progress (LLM summarizer call running).
    /// While true: send button disabled, spinning compaction pill shown.
    /// Orthogonal to `agentPhase`: compaction can run during any phase (including idle)
    /// because the memory-manager triggers it asynchronously. A turn_start resets it.
    var isCompacting = false
    /// Memory retain is in progress (LLM summarizer call running).
    /// While true: Retain button shows a spinner and is disabled.
    var isRetaining = false
    var connectionState: ConnectionState = .disconnected
    var showSettings = false
    var errorMessage: String?
    var showError: Bool { errorMessage != nil }
    /// Set to true when the session doesn't exist on server and view should navigate back
    var shouldDismiss = false
    var isThinkingExpanded = false
    var isRecording = false
    var isTranscribing = false
    /// Whether more older messages are available for loading
    var hasMoreMessages = false
    /// Whether currently loading more messages
    var isLoadingMoreMessages = false

    // MARK: - Display Stream State

    /// Display stream state (active stream, frames, sheet, stop tracking)
    var displayStreamState = DisplayStreamState()

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

    /// Skills staged as chips on the input bar - delegated to inputBarState
    var selectedSkills: [Skill] {
        get { inputBarState.selectedSkills }
        set { inputBarState.selectedSkills = newValue }
    }

    // MARK: - Extracted State Objects

    /// UserInteraction state (sheet, current data, answers)
    let userInteractionState = UserInteractionState()
    /// EngineApproval state (sheet, current data)
    let engineApprovalState = EngineApprovalState()
    /// Context tracking state (tokens, cost, context window)
    let contextState = ContextTrackingState()
    /// Subagent state (tracking spawned subagents for chip UI)
    let subagentState = SubagentState()
    /// Process state (tracking background processes for process list UI)
    let processState = ProcessState()
    /// Whether the process list sheet is presented
    var showProcessSheet = false
    /// Thinking state (for extended thinking display)
    let thinkingState = ThinkingState()
    /// Input bar state (text, attachments, skills, reasoning level)
    let inputBarState = InputBarState()
    /// Message queue state (queued messages waiting for agent.ready)
    let messageQueueState = MessageQueueState()
    /// Whether the abort confirmation dialog should be shown (queue has items)
    var showAbortConfirmation = false
    /// Pending source changes prompt to send after sheet dismissal completes.
    var pendingSourceChangesPrompt: String?
    /// Model picker state (cached models, optimistic updates, switching)
    let modelPickerState: ModelPickerState
    /// Worktree isolation state (status, loading) — read-through to the
    /// shared `WorktreeStatusCache`.
    let worktreeState: WorktreeIsolationState
    /// Git workflow state — lock holder, pending merge, conflict banner,
    /// divergence chips. Populated by worktree/repo event handlers.
    let gitWorkflowState = GitWorkflowState()
    /// Pull-up panel state (suggestions, position, drag)
    let pullUpPanelState = PullUpPanelState()
    // MARK: - Protocol Conformance (Context Protocols)

    /// Whether UserInteraction was called in the current turn (CapabilityInvocationContext, TurnLifecycleContext)
    var userInteractionCalledInTurn: Bool {
        get { userInteractionState.calledInTurn }
        set { userInteractionState.calledInTurn = newValue }
    }

    /// Make a capability visible for rendering (CapabilityInvocationContext)
    func makeCapabilityInvocationVisible(_ invocationId: String) {
        animationCoordinator.makeCapabilityInvocationVisible(invocationId)
    }

    /// Logging methods (LoggingContext)
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

    /// Show error to user (required by LoggingContext, used by all coordinators)
    func showError(_ message: String) {
        handleError(message, severity: .fatal)
    }

    // MARK: - Internal State (accessible to extensions)

    let engineClient: EngineClient
    let sessionId: String
    /// Task for handling event stream from EngineClient
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?
    @ObservationIgnored
    private var eventTaskGeneration: UInt64 = 0
    @ObservationIgnored
    private let contextRefreshGate = ContextRefreshGate()
    /// ID of the thinking message for the current turn (thinking appears before text response)
    var thinkingMessageId: UUID?
    /// True while reconstruction is in progress — buffers real-time events for replay after
    var isReconstructing = false
    /// Events buffered during reconstruction, drained after sequenceHighWaterMark is set.
    @ObservationIgnored
    var eventBuffer: [ParsedEventV2] = []
    /// Highest processed event sequence number. Events with seq <= this are dropped (dedup).
    var sequenceHighWaterMark: Int64 = -1
    /// Oldest sequence from the last reconstruction (for pagination cursor).
    var reconstructionOldestSequence: Int64?
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
    /// ID of the memory-retain-in-progress notification (replaced when retain completes)
    var memoryRetainInProgressMessageId: UUID?
    /// Safety-net timeout: if agent.ready never arrives after agent.complete, warn at 15s, recover at 30s
    @ObservationIgnored
    var postProcessingTimeoutTask: Task<Void, Never>?

    // MARK: - Sub-Managers

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
    /// Coordinates UserInteraction event handling and user interaction
    let userInteractionCoordinator = UserInteractionCoordinator()
    /// Coordinates EngineApproval event handling and user interaction
    let engineApprovalCoordinator = EngineApprovalCoordinator()
    /// Coordinates voice recording and transcription
    let transcriptionCoordinator = TranscriptionCoordinator()
    /// Coordinates message sending, abort, and attachments
    let messagingCoordinator = MessagingCoordinator()
    /// Coordinates session connection, reconnection, and catch-up
    let connectionCoordinator = ConnectionCoordinator()
    /// Coordinates event dispatch - routes plugin events to handlers
    let eventDispatchCoordinator = EventDispatchCoordinator()
    /// Coordinates compaction event handling (start/complete pill transitions)
    let compactionCoordinator = CompactionCoordinator()
    /// Coordinates memory retention event handling (start/complete pill transitions)
    let memoryCoordinator = MemoryCoordinator()
    /// O(1) message lookup index — kept in sync with `messages` array
    let messageIndex = MessageIndex()
    var currentCapabilityInvocationMessages: [UUID: ChatMessage] = [:]

    /// Track capability invocations for the current turn (for display purposes)
    var currentTurnCapabilityInvocations: [CapabilityInvocationRecord] = []

    let audioRecorder: AudioRecorder

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
    /// Number of messages to show initially
    static let initialMessageBatchSize = 100
    /// Number of messages to load on scroll-up
    static let additionalMessageBatchSize = 100
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
    /// Used for instant "Load Earlier Messages" recovery without DB reconstruction.
    @ObservationIgnored
    var prunedLiveMessages: [ChatMessage] = []

    /// Incremented after each prune — view observes this to anchor scroll position.
    var prunedVersion: Int = 0

    // MARK: - Initialization

    init(engineClient: EngineClient, sessionId: String, audioRecorder: AudioRecorder = AudioRecorder(), eventStoreManager: EventStoreManager? = nil) {
        self.engineClient = engineClient
        self.sessionId = sessionId
        self.audioRecorder = audioRecorder
        self.eventStoreManager = eventStoreManager
        self.connectionState = engineClient.connectionState
        self.modelPickerState = ModelPickerState(modelClient: engineClient.model)
        // Worktree state reads through the shared cache when a store manager
        // is available, else a test-local cache that exists only for this view
        // model so tests passing a nil manager still get a working object.
        let cache = eventStoreManager?.worktreeStatusCache
            ?? WorktreeStatusCache(fetch: { [weak engineClient] id in
                guard let engineClient else { throw CancellationError() }
                return try await engineClient.worktree.getStatus(sessionId: id)
            })
        self.worktreeState = WorktreeIsolationState(sessionId: sessionId, cache: cache)
        setupBindings()
        setupEventProcessingCallbacks()
        setupAudioRecorder()
    }

    private var observationTasks: [Task<Void, Never>] = []

    /// Reusable observation loop: watches a value via `withObservationTracking`
    /// and invokes `onChange` each time it changes. Cancelled via the returned Task.
    static func observeLoop<T: Equatable>(
        _ read: @escaping @MainActor () -> T,
        onChange: @escaping @MainActor (T) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                await withCheckedContinuation { cont in
                    withObservationTracking { _ = read() } onChange: { cont.resume() }
                }
                guard !Task.isCancelled else { return }
                onChange(read())
            }
        }
    }

    private func setupBindings() {
        observationTasks.append(Self.observeLoop({ self.engineClient.connectionState }) { [self] state in
            self.connectionState = state

            // Clear stale processing state on disconnect — server may have
            // crashed during post-processing, so agent_ready will never arrive.
            if case .disconnected = state {
                if self.agentPhase != .idle {
                    self.agentPhase = .idle
                }
                self.streamingManager.reset()
                self.isCompacting = false
                self.compactionInProgressMessageId = nil
                self.isRetaining = false
                self.memoryRetainInProgressMessageId = nil
                self.runningCapabilityInvocationCount = 0
                self.clearDisplayStreamState()
                self.clearProcessState()
                self.userInteractionState.clearAll()
                self.engineApprovalState.clearAll()
                self.subagentState.clearAll()
                self.prunedLiveMessages.removeAll()
                self.pullUpPanelState.awaitingSuggestions = false
            }
        })

        observationTasks.append(Self.observeLoop({ self.audioRecorder.isRecording }) { [self] recording in
            self.isRecording = recording
        })

        observationTasks.append(Self.observeLoop({ self.inputBarState.selectedImages }) { [self] images in
            Task { await self.processSelectedImages(images) }
        })
    }

    private func setupAudioRecorder() {
        audioRecorder.onFinish = { [weak self] url, success in
            Task { await self?.handleRecordingFinished(url: url, success: success) }
        }
    }

    /// Set up StreamingManager callbacks for text delta batching
    private func setupStreamingManagerCallbacks() {
        streamingManager.onTextUpdate = { [weak self] messageId, text in
            guard let self = self else { return }
            if let index = self.messageIndex.index(for: messageId) {
                self.messages[index].content = .streaming(text)
                self.messages[index].streamingVersion += 1
            }
        }

        streamingManager.onCreateStreamingMessage = { [weak self] in
            guard let self = self else { return UUID() }
            let message = ChatMessage.streaming()
            self.appendToMessages(message)
            return message.id
        }

        streamingManager.onFinalizeMessage = { [weak self] messageId, finalText in
            guard let self = self else { return }
            if let index = self.messageIndex.index(for: messageId) {
                if finalText.isEmpty {
                    self.removeFromMessages(at: index)
                } else {
                    self.messages[index].content = .text(finalText)
                    self.messages[index].isStreaming = false
                }
            }
        }
    }

    /// Set up UIUpdateQueue callback for processing batched, ordered updates
    private func setupUIUpdateQueueCallback() {
        uiUpdateQueue.onProcessUpdates = { [weak self] updates in
            guard let self = self else { return }

            for update in updates {
                switch update {
                case .turnBoundary(let data):
                    // Turn boundaries are handled directly in handleTurnStart/handleTurnEnd
                    // This callback is for capability ordering confirmation
                    logger.verbose("UIUpdateQueue: Turn boundary processed (turn=\(data.turnNumber), isStart=\(data.isStart))", category: .events)

                case .capabilityInvocationStarted(let data):
                    // Capability start was already added to messages in handleCapabilityInvocationStarted
                    // Here we trigger the staggered animation appearance
                    animationCoordinator.queueCapabilityInvocationStart(invocationId: data.invocationId)
                    logger.verbose("UIUpdateQueue: Capability start queued for animation: \(data.modelPrimitiveName)", category: .events)

                case .capabilityInvocationCompleted(let data):
                    // Capability end arrives here in guaranteed order (earlier capabilities first)
                    // Find and update the capability message
                    processOrderedCapabilityInvocationCompleted(data)
                    animationCoordinator.markCapabilityInvocationComplete(invocationId: data.invocationId)
                    logger.verbose("UIUpdateQueue: Capability end processed in order: \(data.invocationId)", category: .events)

                case .messageAppend, .textDelta:
                    // These are handled separately via direct streaming path
                    break
                }
            }
        }
    }

    /// Process a capability end update that has been ordered by UIUpdateQueue
    private func processOrderedCapabilityInvocationCompleted(_ data: UIUpdateQueue.CapabilityInvocationEndData) {
        // Find the capability message by invocationId (O(1) via index, then a bounded scan)
        if let index = messageIndex.index(forCapabilityInvocationId: data.invocationId)
            ?? MessageFinder.lastIndexOfCapabilityInvocation(id: data.invocationId, in: messages) {
            if case .capabilityInvocation(var invocation) = messages[index].content {
                invocation.status = data.success ? .success : .error
                invocation.result = data.result
                invocation.durationMs = data.durationMs
                invocation.details = data.details
                invocation.progressMessage = nil
                invocation.progressPercent = nil
                invocation.identity = data.identity
                messages[index].content = .capabilityInvocation(invocation)
                messageIndex.didUpdate(messages[index], at: index)

                // Decrement running capability counter (clamp to 0 for catch-up scenarios)
                runningCapabilityInvocationCount = max(0, runningCapabilityInvocationCount - 1)
            }
        }
    }

    private func setupEventProcessingCallbacks() {
        // Set up manager callbacks for batched/ordered processing
        setupUIUpdateQueueCallback()
        setupStreamingManagerCallbacks()
    }

    func startLiveEventStream() {
        // Subscribe to plugin-based event stream from EngineClient using async stream
        // Filter to only handle events for this session
        guard eventTask == nil else { return }
        eventTaskGeneration += 1
        let generation = eventTaskGeneration
        eventTask = Task { [weak self] in
            guard let self else { return }
            logger.info("[LIVE] Starting engine event stream for session \(sessionId)", category: .events)
            for await event in engineClient.events(for: sessionId) {
                guard !Task.isCancelled else { break }
                logger.verbose(
                    "[LIVE] ChatViewModel received event \(event.eventType) session=\(event.sessionId ?? "nil") seq=\(event.sequence?.description ?? "nil")",
                    category: .events
                )
                handleEventV2(event)
            }
            logger.info("[LIVE] Engine event stream ended for session \(sessionId), cancelled=\(Task.isCancelled)", category: .events)
            if self.eventTaskGeneration == generation {
                self.eventTask = nil
            }
        }
    }

    func stopLiveEventStream() {
        eventTaskGeneration += 1
        eventTask?.cancel()
        eventTask = nil
        contextRefreshGate.cancel()
    }

    var liveEventStreamIsActiveForTesting: Bool {
        eventTask != nil
    }

    /// Tracked fire-and-forget tasks — cancelled in deinit to prevent leaks
    @ObservationIgnored
    private var backgroundTasks: [Task<Void, Never>] = []
    /// Launch a tracked background task. Removed from tracking on completion.
    func launchBackground(_ operation: @escaping @Sendable @MainActor () async -> Void) {
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.backgroundTasks.removeAll { $0.isCancelled }
        }
        backgroundTasks.append(task)
    }

    deinit {
        // MainActor classes always deinit on the main actor.
        // assumeIsolated lets the compiler see we can safely access isolated state.
        MainActor.assumeIsolated {
            eventTask?.cancel()
            contextRefreshGate.cancel()
            for task in observationTasks { task.cancel() }
            for task in backgroundTasks { task.cancel() }
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

    /// Handle a plugin-based event by dispatching to the EventDispatchCoordinator
    private func handlePluginEvent(type: String, transform: @Sendable () -> (any EventResult)?) {
        eventDispatchCoordinator.dispatch(type: type, transform: transform, context: self)
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
              case .thinking(let visible, let isExpanded, let isStreaming) = messages[index].content,
              isStreaming else {
            return
        }

        messages[index].content = .thinking(visible: visible, isExpanded: isExpanded, isStreaming: false)
        thinkingState.markStreamingComplete()
    }

    /// Force flush any pending text updates (called before completion)
    func flushPendingTextUpdates() {
        // Delegate to StreamingManager for flushing
        streamingManager.flushPendingText()
    }

    // MARK: - Error Handling

    /// Error severity levels for centralized handling
    enum ErrorSeverity {
        /// Fatal errors - show alert to user, log as error
        case fatal
        /// Warnings - log only, continue operation
        case warning
        /// Info - log for debugging, no user impact
        case info
    }

    /// Centralized error handling with severity levels
    /// - Parameters:
    ///   - message: Error description
    ///   - severity: How serious the error is (fatal shows alert, warning/info just log)
    ///   - category: Log category for filtering
    func handleError(_ message: String, severity: ErrorSeverity = .fatal, category: LogCategory = .session) {
        switch severity {
        case .fatal:
            logger.error(message, category: category)
            errorMessage = message
        case .warning:
            logger.warning(message, category: category)
        case .info:
            logger.info(message, category: category)
        }
    }

    func clearError() {
        errorMessage = nil
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
        guard let sessionId = engineClient.currentSessionId else {
            handleError("No active session", severity: .fatal)
            return
        }

        guard let eventId = message.eventId else {
            handleError("Cannot delete this message", severity: .fatal)
            return
        }

        // Only allow deleting user and assistant messages
        guard message.role == .user || message.role == .assistant else {
            handleError("Cannot delete this type of message: invalid role \(message.role)", severity: .fatal)
            return
        }

        logger.info("Deleting message: eventId=\(eventId)", category: .session)

        do {
            let result = try await engineClient.misc.deleteMessage(
                sessionId,
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
            handleError("Failed to delete message: \(error.localizedDescription)", severity: .fatal)
        }
    }

    // MARK: - Computed Properties

    var shouldShowProcessingIndicator: Bool {
        agentPhase != .idle
    }

    /// Show "Processing..." only when the model is thinking and no other
    /// visual feedback is active (streaming text, thinking block, capability
    /// spinner, or subagent chip).
    ///
    /// Every property read here must be on an @Observable object so SwiftUI
    /// re-evaluates when state changes. StreamingManager is NOT @Observable,
    /// so we check `messages` (which is tracked) instead.
    var shouldShowBreathingLine: Bool {
        guard agentPhase == .processing else { return false }
        if messages.last?.isStreaming == true { return false }
        if isThinkingActivelyStreaming { return false }
        if hasRunningCapabilityInvocations { return false }
        if subagentState.hasRunningSubagents { return false }
        return true
    }

    private var isThinkingActivelyStreaming: Bool {
        guard let id = thinkingMessageId,
              let index = messageIndex.index(for: id),
              case .thinking(_, _, let isStreaming) = messages[index].content else {
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

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var currentModel: String {
        engineClient.currentModel
    }

    var hasActiveSession: Bool {
        engineClient.hasActiveSession
    }

    /// Updates the context window based on available model info
    /// Called by ChatView when models are loaded or model is switched
    func updateContextWindow(from models: [ModelInfo]) {
        if let model = models.first(where: { $0.id == currentModel }) {
            contextState.currentContextWindow = model.contextWindow
        }
    }

    /// Refresh context state from server (authoritative source).
    /// Call after: session resume, model switch, skill add/remove, context clear/compaction.
    /// Syncs both context limit and current token count to keep the pill in sync with the sheet.
    /// When the server returns currentTokens=0 (session not yet built), preserves existing tokens.
    func refreshContextFromServer() async {
        await contextRefreshGate.run { [weak self] in
            await self?.performContextRefreshFromServer()
        }
    }

    private func performContextRefreshFromServer() async {
        guard let sessionId = engineClient.currentSessionId else {
            logger.debug("No session ID available for context refresh", category: .session)
            return
        }

        let contextClient = engineClient.context
        let sid = sessionId
        do {
            let snapshot = try await withRetry {
                try await contextClient.getSnapshot(sessionId: sid)
            }
            self.contextState.syncFromServerSnapshot(
                currentTokens: snapshot.currentTokens,
                contextLimit: snapshot.contextLimit
            )
        } catch {
            logger.warning("refreshContextFromServer failed: \(error.localizedDescription)", category: .session)
        }
    }

    // Note: Deep link methods moved to ChatViewModel+DeepLinks.swift
}
