import SwiftUI
import Combine
import os
import PhotosUI
import UIKit

// MARK: - Chat View Model
// Note: ToolCallRecord is defined in EventStoreManager.swift

@MainActor
class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var isProcessing = false
    @Published var isCatchingUp = false  // True when catching up to an in-progress session
    @Published var connectionState: ConnectionState = .disconnected
    @Published var showSettings = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var selectedImages: [PhotosPickerItem] = []
    @Published var attachments: [Attachment] = []
    @Published var thinkingText = ""
    @Published var isThinkingExpanded = false
    @Published var totalTokenUsage: TokenUsage?
    @Published var isRecording = false
    @Published var isTranscribing = false
    @AppStorage("transcriptionModelId") var transcriptionModelId = ""
    /// Whether more older messages are available for loading
    @Published var hasMoreMessages = false
    /// Whether currently loading more messages
    @Published var isLoadingMoreMessages = false
    /// Current model's context window size (from server's model.list)
    @Published var currentContextWindow: Int = 200_000

    // MARK: - Browser State

    /// Current browser frame image
    @Published var browserFrame: UIImage?
    /// Whether to show the browser sheet
    @Published var showBrowserWindow = false
    /// Current browser status
    @Published var browserStatus: BrowserGetStatusResult?
    /// Whether user manually dismissed browser sheet this turn (prevents auto-reopen)
    var userDismissedBrowserThisTurn = false

    // MARK: - Safari State (OpenBrowser Tool)

    /// URL to open in native Safari (set by OpenBrowser tool)
    @Published var safariURL: URL?

    // MARK: - AskUserQuestion State

    /// Whether to show the AskUserQuestion sheet
    @Published var showAskUserQuestionSheet = false
    /// Current AskUserQuestion tool data (when sheet is open)
    @Published var currentAskUserQuestionData: AskUserQuestionToolData?
    /// Pending answers keyed by question ID
    @Published var askUserQuestionAnswers: [String: AskUserQuestionAnswer] = [:]
    /// Whether AskUserQuestion was called in the current turn (to suppress subsequent text)
    var askUserQuestionCalledInTurn = false

    // MARK: - Plan Mode State

    /// Whether plan mode is currently active
    @Published var isPlanModeActive = false
    /// Name of the skill that activated plan mode
    @Published var planModeSkillName: String?

    // MARK: - Internal State (accessible to extensions)

    let rpcClient: RPCClient
    let sessionId: String
    var cancellables = Set<AnyCancellable>()
    var streamingMessageId: UUID?
    var streamingText = ""

    // MARK: - Sub-Managers (Phase 1: Foundation - initially unused)

    /// Coordinates pill morph animations, message cascade timing, and tool staggering
    let animationCoordinator = AnimationCoordinator()
    /// Ensures tool calls appear in order and batches UI updates for 60fps
    let uiUpdateQueue = UIUpdateQueue()
    /// Manages virtual scrolling with lazy loading and memory-bounded message window
    let messageWindowManager = MessageWindowManager()
    /// Manages text delta batching, thinking content, and backpressure
    let streamingManager = StreamingManager()
    var currentToolMessages: [UUID: ChatMessage] = [:]
    var accumulatedInputTokens = 0
    var accumulatedOutputTokens = 0
    var accumulatedCacheReadTokens = 0
    var accumulatedCacheCreationTokens = 0
    var accumulatedCost: Double = 0
    /// Last turn's input tokens (represents actual current context size)
    var lastTurnInputTokens = 0
    /// Previous turn's final input tokens (for computing incremental delta)
    var previousTurnFinalInputTokens = 0

    /// Track tool calls for the current turn (for display purposes)
    var currentTurnToolCalls: [ToolCallRecord] = []
    let audioRecorder = AudioRecorder()

    /// Track the message index where the current turn started
    /// Used to find which messages to update with metadata at turn_end
    var turnStartMessageIndex: Int?

    /// Track the first text message ID of the current turn
    /// This message gets the token/model/latency metadata at turn_end
    var firstTextMessageIdForTurn: UUID?
    let maxRecordingDuration: TimeInterval = 120

    // MARK: - Performance Optimization: Batched Updates

    var pendingTextDelta = ""
    var textUpdateTask: Task<Void, Never>?
    let textUpdateInterval: UInt64 = 100_000_000 // 100ms in nanoseconds - balances smooth UI with reduced updates
    /// Maximum streaming text size to prevent memory exhaustion (10MB)
    static let maxStreamingTextSize = 10_000_000

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

        // Handle image picker changes
        $selectedImages
            .sink { [weak self] items in
                Task { await self?.processSelectedImages(items) }
            }
            .store(in: &cancellables)

        audioRecorder.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)
    }

    private func setupAudioRecorder() {
        audioRecorder.onFinish = { [weak self] url, success in
            Task { await self?.handleRecordingFinished(url: url, success: success) }
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
            if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
                self.messages[index].content = .streaming(text)
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
            if let index = self.messages.firstIndex(where: { $0.id == messageId }) {
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

        streamingManager.onThinkingUpdate = { [weak self] thinkingText in
            self?.thinkingText = thinkingText
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
        if let index = messages.lastIndex(where: {
            if case .toolUse(let tool) = $0.content {
                return tool.toolCallId == data.toolCallId
            }
            return false
        }) {
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

        rpcClient.onTextDelta = { [weak self] delta in
            self?.handleTextDelta(delta)
        }

        rpcClient.onThinkingDelta = { [weak self] delta in
            self?.handleThinkingDelta(delta)
        }

        rpcClient.onToolStart = { [weak self] event in
            self?.handleToolStart(event)
        }

        rpcClient.onToolEnd = { [weak self] event in
            self?.handleToolEnd(event)
        }

        rpcClient.onTurnStart = { [weak self] event in
            self?.handleTurnStart(event)
        }

        rpcClient.onTurnEnd = { [weak self] event in
            self?.handleTurnEnd(event)
        }

        rpcClient.onAgentTurn = { [weak self] event in
            self?.handleAgentTurn(event)
        }

        rpcClient.onCompaction = { [weak self] event in
            self?.handleCompaction(event)
        }

        rpcClient.onContextCleared = { [weak self] event in
            self?.handleContextCleared(event)
        }

        rpcClient.onMessageDeleted = { [weak self] event in
            self?.handleMessageDeleted(event)
        }

        rpcClient.onSkillRemoved = { [weak self] event in
            self?.handleSkillRemoved(event)
        }

        rpcClient.onPlanModeEntered = { [weak self] event in
            self?.handlePlanModeEntered(event)
        }

        rpcClient.onPlanModeExited = { [weak self] event in
            self?.handlePlanModeExited(event)
        }

        rpcClient.onComplete = { [weak self] in
            self?.handleComplete()
        }

        rpcClient.onError = { [weak self] message in
            self?.handleAgentError(message)
        }

        rpcClient.onBrowserFrame = { [weak self] event in
            self?.handleBrowserFrame(event)
        }

        rpcClient.onBrowserClosed = { [weak self] sessionId in
            self?.handleBrowserClosed(sessionId)
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
        guard let id = streamingMessageId,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].content = content

        // Sync to MessageWindowManager
        messageWindowManager.updateMessage(messages[index])
    }

    func finalizeStreamingMessage() {
        // Use StreamingManager for finalization
        let finalText = streamingManager.finalizeStreamingMessage()

        // Clear legacy state
        streamingMessageId = nil
        streamingText = ""

        // If StreamingManager didn't handle it (already finalized), try legacy cleanup
        if finalText.isEmpty && streamingMessageId == nil {
            // Nothing to do - already handled by StreamingManager callbacks
            return
        }
    }

    /// Force flush any pending text updates (called before completion)
    func flushPendingTextUpdates() {
        // Use StreamingManager for flushing
        streamingManager.flushPendingText()

        // Legacy cleanup
        textUpdateTask?.cancel()
        textUpdateTask = nil
        pendingTextDelta = ""
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
            let result = try await rpcClient.deleteMessage(sessionId, targetEventId: eventId)
            logger.info("Message deleted successfully: deletionEventId=\(result.deletionEventId)", category: .session)

            // Remove the message from local state immediately for responsive UI
            // The server will also send an event.new notification which we handle in Events extension
            await MainActor.run {
                if let index = messages.firstIndex(where: { $0.eventId == eventId }) {
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

    /// Estimated context usage percentage based on last turn's input tokens
    /// (which represents the actual current context size sent to the LLM)
    var contextPercentage: Int {
        guard currentContextWindow > 0 else { return 0 }
        guard lastTurnInputTokens > 0 else { return 0 }

        // Last turn's input tokens = actual context size (system + history + message)
        let percentage = Double(lastTurnInputTokens) / Double(currentContextWindow) * 100

        return min(100, Int(percentage.rounded()))
    }

    /// Updates the context window based on available model info
    /// Called by ChatView when models are loaded or model is switched
    func updateContextWindow(from models: [ModelInfo]) {
        if let model = models.first(where: { $0.id == currentModel }) {
            currentContextWindow = model.contextWindow
        }
    }

    /// Refresh context state from server (authoritative source)
    /// Call after: session resume, model switch, skill add/remove, context clear/compaction
    /// This ensures iOS state stays in sync with server's context calculations
    /// Includes retry logic for transient network failures
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
                let snapshot = try await rpcClient.getContextSnapshot(sessionId: sessionId)
                await MainActor.run {
                    self.currentContextWindow = snapshot.contextLimit
                    self.lastTurnInputTokens = snapshot.currentTokens
                    // Note: Do NOT set previousTurnFinalInputTokens here.
                    // That value is used for incremental token delta calculations and should only be
                    // updated by handleTurnEnd() after a turn completes, or by restoreTokenStateFromMessages()
                    // when loading historical data. Setting it here from the server's current context
                    // causes the delta to incorrectly show 0 for the first turn of a session.
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

        // All retries failed
        if let error = lastError {
            logger.warning("Failed to refresh context from server after \(maxRetries) attempts: \(error.localizedDescription)", category: .session)
        }
    }

    // MARK: - Browser Methods

    /// Handle incoming browser frame from screencast
    func handleBrowserFrame(_ event: BrowserFrameEvent) {
        // Decode base64 JPEG - this is fast enough to do on main thread
        // Streaming at ~10 FPS means ~100ms per frame budget, JPEG decode is <5ms
        guard let data = Data(base64Encoded: event.frameData),
              let image = UIImage(data: data) else {
            return
        }

        browserFrame = image

        // Update browserStatus to reflect that we have an active streaming session
        // This handles the case where BrowserDelegate auto-started streaming
        let wasFirstFrame = browserStatus == nil || browserStatus?.isStreaming != true
        if wasFirstFrame {
            browserStatus = BrowserGetStatusResult(
                hasBrowser: true,
                isStreaming: true,
                currentUrl: browserStatus?.currentUrl
            )
        }

        // Auto-show browser window only on the FIRST frame, and only if user hasn't
        // manually dismissed it during this prompt/response cycle
        if wasFirstFrame && !showBrowserWindow && !userDismissedBrowserThisTurn {
            showBrowserWindow = true
            logger.info("Browser window auto-shown on first frame", category: .session)
        }
    }

    /// Mark browser as dismissed by user (prevents auto-reopen this turn)
    func userDismissedBrowser() {
        userDismissedBrowserThisTurn = true
        showBrowserWindow = false
        logger.info("User dismissed browser sheet - won't auto-reopen this turn", category: .session)
    }

    /// Handle browser session closed
    func handleBrowserClosed(_ sessionId: String) {
        browserFrame = nil
        browserStatus = nil
        showBrowserWindow = false
        logger.info("Browser session closed: \(sessionId)", category: .session)
    }

    /// Request browser status from server
    func requestBrowserStatus() async {
        guard let sessionId = rpcClient.currentSessionId else { return }

        do {
            let status = try await rpcClient.getBrowserStatus(sessionId: sessionId)
            await MainActor.run {
                self.browserStatus = status
            }
        } catch {
            logger.error("Failed to get browser status: \(error)", category: .session)
        }
    }

    /// Start browser streaming
    func startBrowserStream() async {
        guard let sessionId = rpcClient.currentSessionId else { return }

        do {
            let result = try await rpcClient.startBrowserStream(sessionId: sessionId)
            if result.success {
                await MainActor.run {
                    self.browserStatus = BrowserGetStatusResult(
                        hasBrowser: true,
                        isStreaming: true,
                        currentUrl: nil
                    )
                    // Only auto-show if user hasn't manually dismissed this turn
                    if !self.userDismissedBrowserThisTurn {
                        self.showBrowserWindow = true
                    }
                }
                logger.info("Browser stream started", category: .session)
            }
        } catch {
            logger.error("Failed to start browser stream: \(error)", category: .session)
            showErrorAlert("Failed to start browser stream")
        }
    }

    /// Stop browser streaming
    func stopBrowserStream() async {
        guard let sessionId = rpcClient.currentSessionId else { return }

        do {
            _ = try await rpcClient.stopBrowserStream(sessionId: sessionId)
            await MainActor.run {
                self.browserStatus = BrowserGetStatusResult(
                    hasBrowser: self.browserStatus?.hasBrowser ?? false,
                    isStreaming: false,
                    currentUrl: self.browserStatus?.currentUrl
                )
            }
            logger.info("Browser stream stopped", category: .session)
        } catch {
            logger.error("Failed to stop browser stream: \(error)", category: .session)
        }
    }

    /// Close the browser session entirely (stops streaming and clears state)
    func closeBrowserSession() {
        logger.info("Closing browser session", category: .session)
        Task {
            // Stop streaming first
            await stopBrowserStream()
            // Clear all browser state
            await MainActor.run {
                browserFrame = nil
                browserStatus = nil
                showBrowserWindow = false
            }
        }
    }

    /// Toggle browser window visibility (explicit user action via globe button)
    func toggleBrowserWindow() {
        if showBrowserWindow {
            // User is closing via globe - same as dismissing
            userDismissedBrowser()
        } else if hasBrowserSession {
            // User explicitly wants to see browser - override the dismiss flag
            showBrowserWindow = true
            // Start streaming if not already
            if browserStatus?.isStreaming != true {
                Task {
                    await startBrowserStream()
                }
            }
        }
    }

    /// Whether browser toolbar button should be visible
    /// Shows if we have an active browser status OR a browser frame to display
    var hasBrowserSession: Bool {
        (browserStatus?.hasBrowser ?? false) || browserFrame != nil
    }

    // MARK: - AskUserQuestion Methods

    /// Open the AskUserQuestion sheet for a tool call
    func openAskUserQuestionSheet(for data: AskUserQuestionToolData) {
        // Allow opening for pending (to answer) or answered (to view)
        guard data.status == .pending || data.status == .answered else {
            logger.info("Not opening AskUserQuestion sheet - status is \(data.status)", category: .session)
            return
        }
        currentAskUserQuestionData = data
        // Initialize answers from data (in case of re-opening or viewing answered)
        askUserQuestionAnswers = data.answers
        showAskUserQuestionSheet = true
        let mode = data.status == .answered ? "read-only" : "interactive"
        logger.info("Opened AskUserQuestion sheet (\(mode)) for \(data.params.questions.count) questions", category: .session)
    }

    /// Handle AskUserQuestion answers submission (async mode: sends as new prompt)
    func submitAskUserQuestionAnswers(_ answers: [AskUserQuestionAnswer]) async {
        guard let data = currentAskUserQuestionData else {
            logger.error("Cannot submit answers - no current question data", category: .session)
            return
        }

        // Verify the question is still pending (not superseded)
        guard data.status == .pending else {
            logger.warning("Cannot submit answers - question status is \(data.status)", category: .session)
            showErrorAlert("This question is no longer active")
            showAskUserQuestionSheet = false
            currentAskUserQuestionData = nil
            askUserQuestionAnswers = [:]
            return
        }

        // Build the result
        let result = AskUserQuestionResult(
            answers: answers,
            complete: true,
            submittedAt: ISO8601DateFormatter().string(from: Date())
        )

        logger.info("Submitting AskUserQuestion answers as prompt for toolCallId=\(data.toolCallId)", category: .session)

        // Update the chip status to .answered BEFORE sending
        if let index = messages.lastIndex(where: {
            if case .askUserQuestion(let toolData) = $0.content {
                return toolData.toolCallId == data.toolCallId
            }
            return false
        }) {
            if case .askUserQuestion(var toolData) = messages[index].content {
                toolData.status = .answered
                toolData.result = result
                // Convert array to dictionary
                var answersDict: [String: AskUserQuestionAnswer] = [:]
                for answer in answers {
                    answersDict[answer.questionId] = answer
                }
                toolData.answers = answersDict
                messages[index].content = .askUserQuestion(toolData)
            }
        }

        // Format answers as a user prompt and send
        let answerPrompt = formatAnswersAsPrompt(data: data, answers: answers)

        // Clear state before sending
        showAskUserQuestionSheet = false
        currentAskUserQuestionData = nil
        askUserQuestionAnswers = [:]

        // Send as a new prompt (this triggers a new agent turn)
        inputText = answerPrompt
        sendMessage()

        logger.info("AskUserQuestion answers submitted as prompt", category: .session)
    }

    /// Format answers into a user prompt for the agent
    private func formatAnswersAsPrompt(data: AskUserQuestionToolData, answers: [AskUserQuestionAnswer]) -> String {
        var lines: [String] = ["[Answers to your questions]", ""]

        for question in data.params.questions {
            guard let answer = answers.first(where: { $0.questionId == question.id }) else { continue }

            lines.append("**\(question.question)**")

            if let otherValue = answer.otherValue, !otherValue.isEmpty {
                lines.append("Answer: [Other] \(otherValue)")
            } else if !answer.selectedValues.isEmpty {
                let selected = answer.selectedValues.joined(separator: ", ")
                lines.append("Answer: \(selected)")
            } else {
                lines.append("Answer: (no selection)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Mark all pending AskUserQuestion chips as superseded
    /// Called before sending a new user message (when user bypasses answering)
    func markPendingQuestionsAsSuperseded() {
        for i in messages.indices {
            if case .askUserQuestion(var data) = messages[i].content,
               data.status == .pending {
                data.status = .superseded
                messages[i].content = .askUserQuestion(data)
                logger.info("Marked AskUserQuestion \(data.toolCallId) as superseded", category: .session)
            }
        }
    }

    /// Dismiss AskUserQuestion sheet without submitting
    func dismissAskUserQuestionSheet() {
        showAskUserQuestionSheet = false
        logger.info("AskUserQuestion sheet dismissed without submitting", category: .session)
    }

    // MARK: - Plan Mode Methods

    /// Enter plan mode (called from event handler)
    func enterPlanMode(skillName: String, blockedTools: [String]) {
        isPlanModeActive = true
        planModeSkillName = skillName

        // Add notification message to chat
        let notification = ChatMessage(
            role: .system,
            content: .planModeEntered(skillName: skillName, blockedTools: blockedTools)
        )
        messages.append(notification)

        logger.info("Entered plan mode: skill=\(skillName), blocked=\(blockedTools.joined(separator: ", "))", category: .session)
    }

    /// Exit plan mode (called from event handler)
    func exitPlanMode(reason: String, planPath: String?) {
        isPlanModeActive = false
        let skillName = planModeSkillName
        planModeSkillName = nil

        // Add notification message to chat
        let notification = ChatMessage(
            role: .system,
            content: .planModeExited(reason: reason, planPath: planPath)
        )
        messages.append(notification)

        logger.info("Exited plan mode: reason=\(reason), skill=\(skillName ?? "unknown")", category: .session)
    }
}
