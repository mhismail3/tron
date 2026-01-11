import SwiftUI
import Combine
import os
import PhotosUI

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
    @Published var attachedImages: [ImageContent] = []
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

        rpcClient.onComplete = { [weak self] in
            self?.handleComplete()
        }

        rpcClient.onError = { [weak self] message in
            self?.handleError(message)
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

    // MARK: - Computed Properties

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty
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
}
