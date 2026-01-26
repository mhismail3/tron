import SwiftUI
import Combine
import os
import PhotosUI
import UIKit

// MARK: - Chat View Model
// Note: ToolCallRecord is defined in EventStoreManager.swift

@MainActor
class ChatViewModel: ObservableObject, ChatEventContext {

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var showSettings = false
    @Published var errorMessage: String?
    @Published var showError = false
    /// Set to true when the session doesn't exist on server and view should navigate back
    @Published var shouldDismiss = false
    @Published var isThinkingExpanded = false
    @Published var isRecording = false
    @Published var isTranscribing = false
    /// Whether more older messages are available for loading
    @Published var hasMoreMessages = false
    /// Whether currently loading more messages
    @Published var isLoadingMoreMessages = false

    // MARK: - Input State (delegated to InputBarState for backward compatibility)

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

    /// Browser state (frame, status, sheet visibility)
    let browserState = BrowserState()
    /// AskUserQuestion state (sheet, current data, answers)
    let askUserQuestionState = AskUserQuestionState()
    /// Plan mode state (active, skill name)
    let planModeState = PlanModeState()
    /// Context tracking state (tokens, cost, context window)
    let contextState = ContextTrackingState()
    /// Subagent state (tracking spawned subagents for chip UI)
    let subagentState = SubagentState()
    /// UI canvas state (for RenderAppUI tool)
    let uiCanvasState = UICanvasState()
    /// Todo state (for task tracking)
    let todoState = TodoState()
    /// Thinking state (for extended thinking display)
    let thinkingState = ThinkingState()
    /// Input bar state (text, attachments, skills, reasoning level)
    let inputBarState = InputBarState()

    // MARK: - Protocol Conformance (ChatEventContext)
    // These are thin wrappers for protocol conformance only

    /// Whether AskUserQuestion was called in the current turn (ChatEventContext)
    var askUserQuestionCalledInTurn: Bool {
        get { askUserQuestionState.calledInTurn }
        set { askUserQuestionState.calledInTurn = newValue }
    }

    /// Current browser status (ChatEventContext)
    var browserStatus: BrowserGetStatusResult? {
        get { browserState.browserStatus }
        set { browserState.browserStatus = newValue }
    }

    // appendMessage is defined in ChatViewModel+Pagination.swift

    /// Make a tool visible for rendering (ChatEventContext)
    func makeToolVisible(_ toolCallId: String) {
        animationCoordinator.makeToolVisible(toolCallId)
    }

    /// Logging methods (ChatEventContext)
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

    /// Show error to user (shared by BrowserEventContext and AskUserQuestionContext)
    func showError(_ message: String) {
        showErrorAlert(message)
    }

    // MARK: - Internal State (accessible to extensions)

    let rpcClient: RPCClient
    let sessionId: String
    var cancellables = Set<AnyCancellable>()
    /// ID of the thinking message for the current turn (thinking appears before text response)
    var thinkingMessageId: UUID?
    /// ID of the catching-up notification message (removed on turn_end/complete)
    var catchingUpMessageId: UUID?

    // MARK: - Sub-Managers

    /// Coordinates pill morph animations, message cascade timing, and tool staggering
    let animationCoordinator = AnimationCoordinator()
    /// Ensures tool calls appear in order and batches UI updates for 60fps
    let uiUpdateQueue = UIUpdateQueue()
    /// Manages virtual scrolling with lazy loading and memory-bounded message window
    let messageWindowManager = MessageWindowManager()
    /// Manages text delta batching, thinking content, and backpressure
    let streamingManager = StreamingManager()
    /// Extracts and processes event data from agent streaming (stateless handler)
    let eventHandler = ChatEventHandler()
    /// Coordinates tool event handling (start/end) for tool messages and UI updates
    let toolEventCoordinator = ToolEventCoordinator()
    /// Coordinates turn lifecycle handling (start/end, complete)
    let turnLifecycleCoordinator = TurnLifecycleCoordinator()
    /// Coordinates UI canvas rendering event handling
    let uiCanvasCoordinator = UICanvasCoordinator()
    /// Coordinates browser event handling and session lifecycle
    let browserCoordinator = BrowserCoordinator()
    /// Coordinates AskUserQuestion event handling and user interaction
    let askUserQuestionCoordinator = AskUserQuestionCoordinator()
    /// Coordinates voice recording and transcription
    let transcriptionCoordinator = TranscriptionCoordinator()
    /// Coordinates message sending, abort, and attachments
    let messagingCoordinator = MessagingCoordinator()
    var currentToolMessages: [UUID: ChatMessage] = [:]

    /// Track tool calls for the current turn (for display purposes)
    var currentTurnToolCalls: [ToolCallRecord] = []

    /// Tracks RenderAppUI chip messages - consolidates race condition handling
    /// Single source of truth for canvasId → messageId mapping, placeholder IDs, and pending events
    let renderAppUIChipTracker = RenderAppUIChipTracker()

    let audioRecorder = AudioRecorder()

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

    /// Workspace ID for event caching
    var workspaceId: String = ""

    /// Current turn counter
    var currentTurn = 0

    // MARK: - Pagination State

    /// All loaded messages from EventDatabase (full set for pagination)
    var allReconstructedMessages: [ChatMessage] = []
    /// Number of messages to show initially
    static let initialMessageBatchSize = 50
    /// Number of messages to load on scroll-up
    static let additionalMessageBatchSize = 30
    /// Current number of messages displayed (from the end)
    var displayedMessageCount = 0
    /// Whether initial history has been loaded (prevents redundant loads on view re-entry)
    var hasInitiallyLoaded = false

    // MARK: - Initialization

    init(rpcClient: RPCClient, sessionId: String, eventStoreManager: EventStoreManager? = nil) {
        self.rpcClient = rpcClient
        self.sessionId = sessionId
        self.eventStoreManager = eventStoreManager
        setupBindings()
        setupEventHandlers()
        setupAudioRecorder()
    }

    private func setupBindings() {
        rpcClient.$connectionState
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionState)

        // Handle image picker changes - observe inputBarState.selectedImages
        // Using withObservationTracking to react to @Observable changes
        observeSelectedImagesChanges()

        audioRecorder.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)
    }

    private func setupAudioRecorder() {
        audioRecorder.onFinish = { [weak self] url, success in
            Task { await self?.handleRecordingFinished(url: url, success: success) }
        }
    }

    /// Observe changes to inputBarState.selectedImages using Swift Observation
    private func observeSelectedImagesChanges() {
        startImageObservation()
    }

    /// Recursive observation helper for selectedImages changes
    private func startImageObservation() {
        withObservationTracking {
            // Access the property to register for tracking
            _ = self.inputBarState.selectedImages
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Process the new images
                await self.processSelectedImages(self.inputBarState.selectedImages)
                // Re-schedule observation
                self.startImageObservation()
            }
        }
    }

    /// Pre-warm audio session for faster mic button response.
    /// Call this when ChatView appears to eliminate first-tap latency.
    func prewarmAudioSession() {
        audioRecorder.prewarmAudioSession()
    }

    /// Set up StreamingManager callbacks for text delta batching
    private func setupStreamingManagerCallbacks() {
        streamingManager.onTextUpdate = { [weak self] messageId, text in
            guard let self = self else { return }
            // Find and update the streaming message
            if let index = MessageFinder.indexById(messageId, in: self.messages) {
                self.messages[index].content = .streaming(text)
                // Increment version to trigger SwiftUI onChange reliably
                self.messages[index].streamingVersion += 1
                // Sync to MessageWindowManager
                self.messageWindowManager.updateMessage(self.messages[index])
            }
        }

        streamingManager.onCreateStreamingMessage = { [weak self] in
            guard let self = self else { return UUID() }
            let message = ChatMessage.streaming()
            self.messages.append(message)
            // Sync to MessageWindowManager
            self.messageWindowManager.appendMessage(message)
            return message.id
        }

        streamingManager.onFinalizeMessage = { [weak self] messageId, finalText in
            guard let self = self else { return }
            if let index = MessageFinder.indexById(messageId, in: self.messages) {
                if finalText.isEmpty {
                    self.messages.remove(at: index)
                    // Sync removal to MessageWindowManager
                    self.messageWindowManager.removeMessage(id: messageId)
                } else {
                    self.messages[index].content = .text(finalText)
                    self.messages[index].isStreaming = false
                    // Sync to MessageWindowManager
                    self.messageWindowManager.updateMessage(self.messages[index])
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
        // Find the tool message by toolCallId
        if let index = MessageFinder.lastIndexOfToolUse(toolCallId: data.toolCallId, in: messages) {
            if case .toolUse(var tool) = messages[index].content {
                tool.status = data.success ? .success : .error
                tool.result = data.result
                tool.durationMs = data.durationMs
                messages[index].content = .toolUse(tool)

                // Sync to MessageWindowManager
                messageWindowManager.updateMessage(messages[index])
            }
        }
    }

    private func setupEventHandlers() {
        // Set up manager callbacks for batched/ordered processing
        setupUIUpdateQueueCallback()
        setupStreamingManagerCallbacks()

        // Subscribe to plugin-based event stream from RPCClient
        // Filter to only handle events for this session
        rpcClient.eventPublisherV2
            .filter { [weak self] event in
                event.matchesSession(self?.sessionId)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleEventV2(event)
            }
            .store(in: &cancellables)
    }

    /// Unified event handler - dispatches ParsedEventV2 to specific handlers
    private func handleEventV2(_ event: ParsedEventV2) {
        switch event {
        case .plugin(let type, _, _, let transform):
            handlePluginEvent(type: type, transform: transform)

        case .unknown(let type):
            logger.debug("Unknown event type: \(type)", category: .events)
        }
    }

    /// Handle a plugin-based event by extracting its Result and dispatching to the appropriate handler
    private func handlePluginEvent(type: String, transform: @Sendable () -> (any EventResult)?) {
        guard let result = transform() else {
            logger.warning("Failed to transform event: \(type)", category: .events)
            return
        }

        switch type {
        case TextDeltaPlugin.eventType:
            if let r = result as? TextDeltaPlugin.Result {
                handleTextDelta(r.delta)
            }

        case ThinkingDeltaPlugin.eventType:
            if let r = result as? ThinkingDeltaPlugin.Result {
                handleThinkingDelta(r.delta)
            }

        case ToolStartPlugin.eventType:
            if let r = result as? ToolStartPlugin.Result {
                handleToolStartResult(r)
            }

        case ToolEndPlugin.eventType:
            if let r = result as? ToolEndPlugin.Result {
                handleToolEndResult(r)
            }

        case TurnStartPlugin.eventType:
            if let r = result as? TurnStartPlugin.Result {
                handleTurnStartResult(r)
            }

        case TurnEndPlugin.eventType:
            if let r = result as? TurnEndPlugin.Result {
                handleTurnEndResult(r)
            }

        case AgentTurnPlugin.eventType:
            if let r = result as? AgentTurnPlugin.Result {
                handleAgentTurnResult(r)
            }

        case CompletePlugin.eventType:
            handleComplete()

        case ErrorPlugin.eventType:
            if let r = result as? ErrorPlugin.Result {
                handleAgentError(r.message)
            }

        case CompactionPlugin.eventType:
            if let r = result as? CompactionPlugin.Result {
                handleCompactionResult(r)
            }

        case ContextClearedPlugin.eventType:
            if let r = result as? ContextClearedPlugin.Result {
                handleContextClearedResult(r)
            }

        case MessageDeletedPlugin.eventType:
            if let r = result as? MessageDeletedPlugin.Result {
                handleMessageDeletedResult(r)
            }

        case SkillRemovedPlugin.eventType:
            if let r = result as? SkillRemovedPlugin.Result {
                handleSkillRemovedResult(r)
            }

        case PlanModeEnteredPlugin.eventType:
            if let r = result as? PlanModeEnteredPlugin.Result {
                handlePlanModeEnteredResult(r)
            }

        case PlanModeExitedPlugin.eventType:
            if let r = result as? PlanModeExitedPlugin.Result {
                handlePlanModeExitedResult(r)
            }

        case BrowserFramePlugin.eventType:
            if let r = result as? BrowserFramePlugin.Result {
                handleBrowserFrameResult(r)
            }

        case BrowserClosedPlugin.eventType:
            if let r = result as? BrowserClosedPlugin.Result {
                if let sessionId = r.closedSessionId {
                    handleBrowserClosed(sessionId)
                }
            }

        case SubagentSpawnedPlugin.eventType:
            if let r = result as? SubagentSpawnedPlugin.Result {
                handleSubagentSpawnedResult(r)
            }

        case SubagentStatusPlugin.eventType:
            if let r = result as? SubagentStatusPlugin.Result {
                handleSubagentStatusResult(r)
            }

        case SubagentCompletedPlugin.eventType:
            if let r = result as? SubagentCompletedPlugin.Result {
                handleSubagentCompletedResult(r)
            }

        case SubagentFailedPlugin.eventType:
            if let r = result as? SubagentFailedPlugin.Result {
                handleSubagentFailedResult(r)
            }

        case SubagentEventPlugin.eventType:
            if let r = result as? SubagentEventPlugin.Result {
                handleSubagentForwardedEventResult(r)
            }

        case UIRenderStartPlugin.eventType:
            if let r = result as? UIRenderStartPlugin.Result {
                handleUIRenderStartResult(r)
            }

        case UIRenderChunkPlugin.eventType:
            if let r = result as? UIRenderChunkPlugin.Result {
                handleUIRenderChunkResult(r)
            }

        case UIRenderCompletePlugin.eventType:
            if let r = result as? UIRenderCompletePlugin.Result {
                handleUIRenderCompleteResult(r)
            }

        case UIRenderErrorPlugin.eventType:
            if let r = result as? UIRenderErrorPlugin.Result {
                handleUIRenderErrorResult(r)
            }

        case UIRenderRetryPlugin.eventType:
            if let r = result as? UIRenderRetryPlugin.Result {
                handleUIRenderRetryResult(r)
            }

        case TodosUpdatedPlugin.eventType:
            if let r = result as? TodosUpdatedPlugin.Result {
                handleTodosUpdatedResult(r)
            }

        case ConnectedPlugin.eventType:
            // Connection events are handled elsewhere
            break

        default:
            logger.debug("Unhandled plugin event type: \(type)", category: .events)
        }
    }

    // MARK: - Windowed Messages (for virtual scrolling)

    /// Use windowed messages for large sessions (150 message memory cap)
    /// Falls back to regular messages array if window manager not initialized
    var windowedMessages: [ChatMessage] {
        let windowed = messageWindowManager.windowedMessages
        return windowed.isEmpty ? messages : windowed
    }

    /// Whether more older messages are available (from MessageWindowManager)
    var hasMoreOlderMessages: Bool {
        messageWindowManager.hasMoreOlder
    }

    /// Load older messages through MessageWindowManager
    func loadOlderMessages() async {
        await messageWindowManager.loadOlder()
    }

    // MARK: - Message Updates

    func updateStreamingMessage(with content: MessageContent) {
        guard let id = streamingManager.streamingMessageId,
              let index = MessageFinder.indexById(id, in: messages) else {
            return
        }
        messages[index].content = content

        // Sync to MessageWindowManager
        messageWindowManager.updateMessage(messages[index])
    }

    func finalizeStreamingMessage() {
        // Use StreamingManager for finalization (clears streamingMessageId and streamingText)
        _ = streamingManager.finalizeStreamingMessage()
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
            showError = true
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
        showError = false
    }

    // MARK: - Commands

    func clearMessages() {
        messages = []
        renderAppUIChipTracker.clearAll()
    }

    /// Add an in-chat notification when model is switched
    func addModelChangeNotification(from previousModel: String, to newModel: String) {
        let notification = ChatMessage.modelChange(
            from: previousModel.shortModelName,
            to: newModel.shortModelName
        )
        messages.append(notification)
        logger.info("Model switched from \(previousModel) to \(newModel)", category: .session)
    }

    /// Add an in-chat notification when reasoning level is changed
    func addReasoningLevelChangeNotification(from previousLevel: String, to newLevel: String) {
        let notification = ChatMessage.reasoningLevelChange(
            from: previousLevel.capitalized,
            to: newLevel.capitalized
        )
        messages.append(notification)
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
                if let index = MessageFinder.indexByEventId(eventId, in: messages) {
                    messages.remove(at: index)
                }
            }
        } catch {
            logger.error("Failed to delete message: \(error)", category: .session)
            showErrorAlert("Failed to delete message: \(error.localizedDescription)")
        }
    }

    // MARK: - Computed Properties

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

    /// Refresh context state from server (authoritative source for ACTIVE sessions)
    /// Call after: session resume, model switch, skill add/remove, context clear/compaction
    /// This ensures iOS state stays in sync with server's live context calculations
    /// Includes retry logic for transient network failures
    ///
    /// IMPORTANT: When the session is NOT active on the server (e.g., during resume before
    /// the user sends a message), the server returns currentTokens=0. In this case, we
    /// preserve the reconstructed state value (from parsing server events).
    /// The reconstructed state is the source of truth for inactive sessions.
    func refreshContextFromServer() async {
        guard let sessionId = rpcClient.currentSessionId else {
            logger.debug("No session ID available for context refresh", category: .session)
            return
        }

        // Retry up to 3 times with exponential backoff (100ms, 200ms, 400ms)
        let maxRetries = 3
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                let snapshot = try await rpcClient.context.getSnapshot(sessionId: sessionId)
                await MainActor.run {
                    // =============================================================================
                    // CONTEXT SNAPSHOT PURPOSE
                    // =============================================================================
                    // The context.getSnapshot RPC returns:
                    // - contextLimit: Maximum tokens for the model (e.g., 200k)
                    // - currentTokens: Current ESTIMATED context (system prompt + tools + messages)
                    //
                    // CRITICAL: currentTokens is NOT the same as normalizedUsage.contextWindowTokens!
                    // - contextWindowTokens (stored in turn_end events) = actual tokens sent to LLM
                    // - currentTokens (from getSnapshot) = current context estimate
                    //
                    // We ONLY use the snapshot for:
                    // 1. Getting the context limit (model's max tokens)
                    // 2. Updating token count DURING LIVE streaming (handled by handleTurnEnd)
                    //
                    // We do NOT use it to update lastTurnInputTokens during resume because:
                    // - The reconstructed state already has the correct value from turn_end events
                    // - The snapshot's currentTokens measures something different
                    // =============================================================================

                    // Update context limit (model's max tokens)
                    self.contextState.currentContextWindow = snapshot.contextLimit

                    // Do NOT update lastTurnInputTokens here!
                    // The reconstructed state (from parsing stream.turn_end events) is the
                    // single source of truth for context window tokens.
                    logger.debug("[TOKEN-FIX] refreshContextFromServer: contextLimit=\(snapshot.contextLimit), currentTokens=\(snapshot.currentTokens) (NOT updating lastTurnInputTokens, using reconstructed value: \(self.contextState.lastTurnInputTokens))", category: .session)
                }
                logger.debug("Context refreshed from server: \(snapshot.currentTokens)/\(snapshot.contextLimit)", category: .session)
                return  // Success, exit retry loop
            } catch {
                lastError = error
                if attempt < maxRetries {
                    // Exponential backoff: 100ms, 200ms, 400ms
                    let delayMs = UInt64(100 * (1 << (attempt - 1)))
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    logger.debug("Context refresh attempt \(attempt) failed, retrying in \(delayMs)ms", category: .session)
                }
            }
        }

        // All retries failed - preserve reconstructed state value
        if let error = lastError {
            logger.warning("Failed to refresh context from server after \(maxRetries) attempts: \(error.localizedDescription). Preserving reconstructed state value: \(contextState.lastTurnInputTokens)", category: .session)
        }
    }

    // Note: Deep link methods moved to ChatViewModel+DeepLinks.swift
}
