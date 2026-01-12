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
    /// Whether to show the floating browser window
    @Published var showBrowserWindow = false
    /// Current browser status
    @Published var browserStatus: BrowserGetStatusResult?

    // MARK: - Internal State (accessible to extensions)

    let rpcClient: RPCClient
    let sessionId: String
    var cancellables = Set<AnyCancellable>()
    var streamingMessageId: UUID?
    var streamingText = ""
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
    let textUpdateInterval: UInt64 = 50_000_000 // 50ms in nanoseconds

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

    private func setupEventHandlers() {
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

        rpcClient.onComplete = { [weak self] in
            self?.handleComplete()
        }

        rpcClient.onError = { [weak self] message in
            self?.handleError(message)
        }

        rpcClient.onBrowserFrame = { [weak self] event in
            self?.handleBrowserFrame(event)
        }

        rpcClient.onBrowserClosed = { [weak self] sessionId in
            self?.handleBrowserClosed(sessionId)
        }
    }

    // MARK: - Message Updates

    func updateStreamingMessage(with content: MessageContent) {
        guard let id = streamingMessageId,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].content = content
    }

    func finalizeStreamingMessage() {
        guard let id = streamingMessageId,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }

        if streamingText.isEmpty {
            messages.remove(at: index)
        } else {
            messages[index].content = .text(streamingText)
            messages[index].isStreaming = false
        }

        streamingMessageId = nil
        streamingText = ""
    }

    /// Force flush any pending text updates (called before completion)
    func flushPendingTextUpdates() {
        textUpdateTask?.cancel()
        textUpdateTask = nil
        if !pendingTextDelta.isEmpty {
            updateStreamingMessage(with: .streaming(streamingText))
            pendingTextDelta = ""
        }
    }

    // MARK: - Error Handling

    /// Show error alert (accessible from external callers like ChatView)
    func showErrorAlert(_ message: String) {
        errorMessage = message
        showError = true
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

        // Auto-show browser window only on the FIRST frame (not subsequent frames)
        // This allows user to close the window and have it stay closed
        if wasFirstFrame && !showBrowserWindow {
            showBrowserWindow = true
            logger.info("Browser window auto-shown on first frame", category: .session)
        }
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
                    self.showBrowserWindow = true
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

    /// Toggle browser window visibility
    func toggleBrowserWindow() {
        if showBrowserWindow {
            showBrowserWindow = false
        } else if browserStatus?.hasBrowser == true {
            showBrowserWindow = true
            // Start streaming if not already
            if browserStatus?.isStreaming != true {
                Task {
                    await startBrowserStream()
                }
            }
        }
    }

    /// Whether browser toolbar button should be enabled
    var hasBrowserSession: Bool {
        browserStatus?.hasBrowser ?? false
    }
}
