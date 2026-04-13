import SwiftUI
import PhotosUI
import UIKit

// MARK: - Chat View Model
// Note: ToolCallRecord is defined in EventStoreManager.swift

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

    // MARK: - Extracted State Objects

    /// AskUserQuestion state (sheet, current data, answers)
    let askUserQuestionState = AskUserQuestionState()
    /// GetConfirmation state (sheet, current data)
    let getConfirmationState = GetConfirmationState()
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
    /// Worktree isolation state (status, loading)
    let worktreeState = WorktreeIsolationState()
    /// Pull-up panel state (suggestions, position, drag)
    let pullUpPanelState = PullUpPanelState()
    // MARK: - Protocol Conformance (Context Protocols)

    /// Whether AskUserQuestion was called in the current turn (ToolEventContext, TurnLifecycleContext)
    var askUserQuestionCalledInTurn: Bool {
        get { askUserQuestionState.calledInTurn }
        set { askUserQuestionState.calledInTurn = newValue }
    }

    /// Whether GetConfirmation was called in the current turn (ToolEventContext)
    var getConfirmationCalledInTurn: Bool {
        get { getConfirmationState.calledInTurn }
        set { getConfirmationState.calledInTurn = newValue }
    }

    /// Make a tool visible for rendering (ToolEventContext)
    func makeToolVisible(_ toolCallId: String) {
        animationCoordinator.makeToolVisible(toolCallId)
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
        showErrorAlert(message)
    }

    // MARK: - Internal State (accessible to extensions)

    let rpcClient: RPCClient
    let sessionId: String
    /// Task for handling event stream from RPCClient
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?
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
    /// ID of the compaction-in-progress notification (replaced when compaction completes)
    var compactionInProgressMessageId: UUID?
    /// ID of the memory-retain-in-progress notification (replaced when retain completes)
    var memoryRetainInProgressMessageId: UUID?
    /// Safety-net timeout: if agent.ready never arrives after agent.complete, warn at 15s, recover at 30s
    @ObservationIgnored
    var postProcessingTimeoutTask: Task<Void, Never>?

    // MARK: - Sub-Managers

    /// Coordinates pill morph animations, message cascade timing, and tool staggering
    let animationCoordinator = AnimationCoordinator()
    /// Ensures tool calls appear in order and batches UI updates for 60fps
    let uiUpdateQueue = UIUpdateQueue()
    /// Manages text delta batching, thinking content, and backpressure
    let streamingManager = StreamingManager()
    /// Coordinates tool event handling (start/end) for tool messages and UI updates
    let toolEventCoordinator = ToolEventCoordinator()
    /// Coordinates turn lifecycle handling (start/end, complete)
    let turnLifecycleCoordinator = TurnLifecycleCoordinator()
    /// Coordinates AskUserQuestion event handling and user interaction
    let askUserQuestionCoordinator = AskUserQuestionCoordinator()
    /// Coordinates GetConfirmation event handling and user interaction
    let getConfirmationCoordinator = GetConfirmationCoordinator()
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
    var currentToolMessages: [UUID: ChatMessage] = [:]

    /// Track tool calls for the current turn (for display purposes)
    var currentTurnToolCalls: [ToolCallRecord] = []

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

    init(rpcClient: RPCClient, sessionId: String, audioRecorder: AudioRecorder = AudioRecorder(), eventStoreManager: EventStoreManager? = nil) {
        self.rpcClient = rpcClient
        self.sessionId = sessionId
        self.audioRecorder = audioRecorder
        self.eventStoreManager = eventStoreManager
        self.connectionState = rpcClient.connectionState
        self.modelPickerState = ModelPickerState(modelClient: rpcClient.model)
        setupBindings()
        setupEventHandlers()
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
        observationTasks.append(Self.observeLoop({ self.rpcClient.connectionState }) { [self] state in
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
                self.runningToolCount = 0
                self.clearDisplayStreamState()
                self.clearProcessState()
                self.askUserQuestionState.clearAll()
                self.getConfirmationState.clearAll()
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
                    // This callback is for tool ordering confirmation
                    logger.verbose("UIUpdateQueue: Turn boundary processed (turn=\(data.turnNumber), isStart=\(data.isStart))", category: .events)

                case .toolStart(let data):
                    // Tool start was already added to messages in handleToolStart
                    // Here we trigger the staggered animation appearance
                    animationCoordinator.queueToolStart(toolCallId: data.toolCallId)
                    logger.verbose("UIUpdateQueue: Tool start queued for animation: \(data.toolName)", category: .events)

                case .toolEnd(let data):
                    // Tool end arrives here in guaranteed order (earlier tools first)
                    // Find and update the tool message
                    processOrderedToolEnd(data)
                    animationCoordinator.markToolComplete(toolCallId: data.toolCallId)
                    logger.verbose("UIUpdateQueue: Tool end processed in order: \(data.toolCallId)", category: .events)

                case .messageAppend, .textDelta:
                    // These are handled separately via direct streaming path
                    break
                }
            }
        }
    }

    /// Process a tool end update that has been ordered by UIUpdateQueue
    private func processOrderedToolEnd(_ data: UIUpdateQueue.ToolEndData) {
        // Find the tool message by toolCallId (O(1) via index, fallback to linear scan)
        if let index = messageIndex.index(forToolCallId: data.toolCallId)
            ?? MessageFinder.lastIndexOfToolUse(toolCallId: data.toolCallId, in: messages) {
            if case .toolUse(var tool) = messages[index].content {
                tool.status = data.success ? .success : .error
                tool.result = data.result
                tool.durationMs = data.durationMs
                tool.details = data.details
                tool.streamingOutput = nil
                messages[index].content = .toolUse(tool)
                messageIndex.didUpdate(messages[index], at: index)

                // Decrement running tool counter (clamp to 0 for catch-up scenarios)
                runningToolCount = max(0, runningToolCount - 1)
            }
        }
    }

    private func setupEventHandlers() {
        // Set up manager callbacks for batched/ordered processing
        setupUIUpdateQueueCallback()
        setupStreamingManagerCallbacks()

        // Subscribe to plugin-based event stream from RPCClient using async stream
        // Filter to only handle events for this session
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in rpcClient.events(for: sessionId) {
                guard !Task.isCancelled else { break }
                handleEventV2(event)
            }
        }
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
        dispatchEvent(event)
    }

    /// Dispatch a single event to the appropriate handler
    func dispatchEvent(_ event: ParsedEventV2) {
        switch event {
        case .plugin(let type, _, _, let transform):
            handlePluginEvent(type: type, transform: transform)
        case .unknown(let type):
            logger.debug("Unknown event type: \(type)", category: .events)
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

    /// Show error alert (legacy, prefer handleError with severity)
    func showErrorAlert(_ message: String) {
        handleError(message, severity: .fatal)
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
    /// This sends an RPC request to append a message.deleted event.
    /// The message will be filtered out during two-pass reconstruction.
    func deleteMessage(_ message: ChatMessage) async {
        guard let sessionId = rpcClient.currentSessionId else {
            logger.error("Cannot delete message - no active session", category: .session)
            showErrorAlert("No active session")
            return
        }

        guard let eventId = message.eventId else {
            logger.error("Cannot delete message - no event ID", category: .session)
            showErrorAlert("Cannot delete this message")
            return
        }

        // Only allow deleting user and assistant messages
        guard message.role == .user || message.role == .assistant else {
            logger.error("Cannot delete message - invalid role: \(message.role)", category: .session)
            showErrorAlert("Cannot delete this type of message")
            return
        }

        logger.info("Deleting message: eventId=\(eventId)", category: .session)

        do {
            let result = try await rpcClient.misc.deleteMessage(sessionId, targetEventId: eventId)
            logger.info("Message deleted successfully: deletionEventId=\(result.deletionEventId)", category: .session)

            // Remove the message from local state immediately for responsive UI
            // The server will also send an event.new notification which we handle in Events extension
            await MainActor.run {
                if let index = MessageFinder.indexByEventId(eventId, in: self.messages) {
                    self.removeFromMessages(at: index)
                }
            }
        } catch {
            logger.error("Failed to delete message: \(error)", category: .session)
            showErrorAlert("Failed to delete message: \(error.localizedDescription)")
        }
    }

    // MARK: - Computed Properties

    var shouldShowProcessingIndicator: Bool {
        agentPhase != .idle
    }

    /// Show "Processing..." only when the model is thinking and no other
    /// visual feedback is active (streaming text, thinking block, tool
    /// spinner, or subagent chip).
    ///
    /// Every property read here must be on an @Observable object so SwiftUI
    /// re-evaluates when state changes. StreamingManager is NOT @Observable,
    /// so we check `messages` (which is tracked) instead.
    var shouldShowBreathingLine: Bool {
        guard agentPhase == .processing else { return false }
        if messages.last?.isStreaming == true { return false }
        if isThinkingActivelyStreaming { return false }
        if hasRunningTools { return false }
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

    /// Counter-based running tool detection — O(1) instead of O(n*m) scan.
    /// Incremented in tool start handler, decremented in processOrderedToolEnd and tool end handler.
    /// Reset on turn start and disconnect.
    var runningToolCount: Int = 0

    private var hasRunningTools: Bool {
        runningToolCount > 0
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var currentModel: String {
        rpcClient.currentModel
    }

    var hasActiveSession: Bool {
        rpcClient.hasActiveSession
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
        guard let sessionId = rpcClient.currentSessionId else {
            logger.debug("No session ID available for context refresh", category: .session)
            return
        }

        let contextClient = rpcClient.context
        let sid = sessionId
        do {
            let snapshot = try await withRetry {
                try await contextClient.getSnapshot(sessionId: sid)
            }
            self.contextState.syncFromServerSnapshot(
                currentTokens: snapshot.currentTokens,
                contextLimit: snapshot.contextLimit
            )
            logger.debug("refreshContextFromServer: contextLimit=\(snapshot.contextLimit), currentTokens=\(snapshot.currentTokens), contextWindowTokens=\(self.contextState.contextWindowTokens)", category: .session)
        } catch {
            logger.warning("Failed to refresh context from server: \(error.localizedDescription). Preserving state: \(contextState.contextWindowTokens)", category: .session)
        }
    }

    // Note: Deep link methods moved to ChatViewModel+DeepLinks.swift
}
