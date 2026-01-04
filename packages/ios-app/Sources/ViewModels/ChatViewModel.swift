import SwiftUI
import Combine
import os
import PhotosUI

// MARK: - Chat View Model

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

    // MARK: - Private State

    private let rpcClient: RPCClient
    private let sessionId: String
    private var cancellables = Set<AnyCancellable>()
    private var streamingMessageId: UUID?
    private var streamingText = ""
    private var currentToolMessages: [UUID: ChatMessage] = [:]
    private var accumulatedInputTokens = 0
    private var accumulatedOutputTokens = 0

    // MARK: - Performance Optimization: Batched Updates

    private var pendingTextDelta = ""
    private var textUpdateTask: Task<Void, Never>?
    private let textUpdateInterval: UInt64 = 50_000_000 // 50ms in nanoseconds

    // MARK: - Initialization

    /// Reference to SessionStore for message persistence
    private weak var sessionStore: SessionStore?

    init(rpcClient: RPCClient, sessionId: String, sessionStore: SessionStore? = nil) {
        self.rpcClient = rpcClient
        self.sessionId = sessionId
        self.sessionStore = sessionStore
        setupBindings()
        setupEventHandlers()
    }

    /// Set the session store reference (used when injected via environment)
    func setSessionStore(_ store: SessionStore) {
        self.sessionStore = store
        loadPersistedMessages()
    }

    /// Load persisted messages from SessionStore
    private func loadPersistedMessages() {
        guard let store = sessionStore else { return }
        let storedMessages = store.getMessages(for: sessionId)

        messages = storedMessages.compactMap { stored -> ChatMessage? in
            let role: MessageRole
            switch stored.role {
            case "user": role = .user
            case "assistant": role = .assistant
            case "system": role = .system
            case "toolResult": role = .toolResult
            default: role = .assistant
            }

            if let toolName = stored.toolName {
                let tool = ToolUseData(
                    toolName: toolName,
                    toolCallId: stored.id.uuidString,
                    arguments: "",
                    status: stored.toolResult != nil ? .success : .running,
                    result: stored.toolResult
                )
                return ChatMessage(id: stored.id, role: role, content: .toolUse(tool), timestamp: stored.timestamp)
            }

            return ChatMessage(id: stored.id, role: role, content: .text(stored.content), timestamp: stored.timestamp)
        }

        log.info("Loaded \(messages.count) persisted messages for session \(sessionId)", category: .session)
    }

    /// Persist current messages to SessionStore
    private func persistMessages() {
        guard let store = sessionStore else { return }

        let storedMessages = messages.compactMap { msg -> SessionStore.StoredMessage? in
            let roleString: String
            switch msg.role {
            case .user: roleString = "user"
            case .assistant: roleString = "assistant"
            case .system: roleString = "system"
            case .toolResult: roleString = "toolResult"
            }

            switch msg.content {
            case .text(let text), .streaming(let text):
                return SessionStore.StoredMessage(
                    id: msg.id,
                    role: roleString,
                    content: text,
                    timestamp: msg.timestamp,
                    toolName: nil,
                    toolResult: nil
                )
            case .toolUse(let tool):
                return SessionStore.StoredMessage(
                    id: msg.id,
                    role: roleString,
                    content: tool.displayName,
                    timestamp: msg.timestamp,
                    toolName: tool.toolName,
                    toolResult: tool.result
                )
            case .error(let error):
                return SessionStore.StoredMessage(
                    id: msg.id,
                    role: roleString,
                    content: error,
                    timestamp: msg.timestamp,
                    toolName: nil,
                    toolResult: nil
                )
            default:
                return nil
            }
        }

        store.saveMessages(storedMessages, for: sessionId)
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

        rpcClient.onComplete = { [weak self] in
            self?.handleComplete()
        }

        rpcClient.onError = { [weak self] message in
            self?.handleError(message)
        }
    }

    // MARK: - Connection & Session

    func connectAndResume() async {
        log.info("connectAndResume() called for session \(sessionId)", category: .session)

        // Connect to server
        log.debug("Calling rpcClient.connect()...", category: .session)
        await rpcClient.connect()

        // Wait for connection
        log.verbose("Waiting 500ms for connection to stabilize...", category: .session)
        try? await Task.sleep(for: .milliseconds(500))

        guard rpcClient.isConnected else {
            log.warning("Failed to connect to server - rpcClient.isConnected=false", category: .session)
            return
        }
        log.info("Connected to server successfully", category: .session)

        // Resume the session
        do {
            log.debug("Calling resumeSession for \(sessionId)...", category: .session)
            try await rpcClient.resumeSession(sessionId: sessionId)
            log.info("Session resumed successfully", category: .session)
        } catch {
            log.error("Failed to resume session: \(error.localizedDescription)", category: .session)
            showErrorAlert("Failed to resume session: \(error.localizedDescription)")
            return
        }

        // Try to load message history (non-critical, may not be supported)
        do {
            log.debug("Fetching session history...", category: .session)
            let history = try await rpcClient.getSessionHistory()
            messages = history.map { historyToMessage($0) }
            log.info("Loaded \(history.count) messages from history", category: .session)
        } catch {
            // History fetch is optional - server may not support it
            log.debug("Could not fetch history (may not be supported): \(error.localizedDescription)", category: .session)
        }
    }

    func disconnect() async {
        await rpcClient.disconnect()
    }

    private func historyToMessage(_ history: HistoryMessage) -> ChatMessage {
        let role: MessageRole = switch history.role {
        case "user": .user
        case "assistant": .assistant
        case "system": .system
        default: .assistant
        }

        return ChatMessage(
            role: role,
            content: .text(history.content)
        )
    }

    // MARK: - Message Sending

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else {
            log.verbose("sendMessage() called but no text or images to send", category: .chat)
            return
        }

        log.info("Sending message: \"\(text.prefix(100))...\" with \(attachedImages.count) images", category: .chat)

        // Create user message
        if !attachedImages.isEmpty {
            let imageMessage = ChatMessage(role: .user, content: .images(attachedImages))
            messages.append(imageMessage)
            log.debug("Added image message with \(attachedImages.count) images", category: .chat)
        }

        if !text.isEmpty {
            let userMessage = ChatMessage.user(text)
            messages.append(userMessage)
            log.debug("Added user text message", category: .chat)
        }

        inputText = ""
        isProcessing = true
        thinkingText = ""

        // Create streaming placeholder
        let streamingMessage = ChatMessage.streaming()
        messages.append(streamingMessage)
        streamingMessageId = streamingMessage.id
        streamingText = ""
        log.verbose("Created streaming placeholder message id=\(streamingMessage.id)", category: .chat)

        // Prepare image attachments
        let imageAttachments = attachedImages.map {
            ImageAttachment(data: $0.data, mimeType: $0.mimeType)
        }
        attachedImages = []
        selectedImages = []

        // Send to server
        Task {
            do {
                log.debug("Calling rpcClient.sendPrompt()...", category: .chat)
                try await rpcClient.sendPrompt(
                    text,
                    images: imageAttachments.isEmpty ? nil : imageAttachments
                )
                log.info("Prompt sent successfully", category: .chat)
            } catch {
                log.error("Failed to send prompt: \(error.localizedDescription)", category: .chat)
                handleError(error.localizedDescription)
            }
        }
    }

    func abortAgent() {
        log.info("Aborting agent...", category: .chat)
        Task {
            do {
                try await rpcClient.abortAgent()
                isProcessing = false
                finalizeStreamingMessage()
                messages.append(.system("Agent aborted"))
                log.info("Agent aborted successfully", category: .chat)
            } catch {
                log.error("Failed to abort agent: \(error.localizedDescription)", category: .chat)
                showErrorAlert(error.localizedDescription)
            }
        }
    }

    // MARK: - Image Handling

    private func processSelectedImages(_ items: [PhotosPickerItem]) async {
        var newImages: [ImageContent] = []

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                // Determine mime type
                let mimeType = "image/jpeg" // Default to JPEG
                newImages.append(ImageContent(data: data, mimeType: mimeType))
            }
        }

        await MainActor.run {
            self.attachedImages.append(contentsOf: newImages)
        }
    }

    func removeAttachedImage(_ image: ImageContent) {
        attachedImages.removeAll { $0.id == image.id }
    }

    // MARK: - Event Handlers

    private func handleTextDelta(_ delta: String) {
        // Batch text deltas for better performance
        pendingTextDelta += delta
        streamingText += delta

        // Cancel any pending update task
        textUpdateTask?.cancel()

        // Schedule batched update (coalesce rapid updates)
        textUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.textUpdateInterval ?? 50_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.updateStreamingMessage(with: .streaming(self.streamingText))
                self.pendingTextDelta = ""
            }
        }

        log.verbose("Text delta received: +\(delta.count) chars, total: \(streamingText.count)", category: .events)
    }

    /// Force flush any pending text updates (called before completion)
    private func flushPendingTextUpdates() {
        textUpdateTask?.cancel()
        textUpdateTask = nil
        if !pendingTextDelta.isEmpty {
            updateStreamingMessage(with: .streaming(streamingText))
            pendingTextDelta = ""
        }
    }

    private func handleThinkingDelta(_ delta: String) {
        thinkingText += delta
        log.verbose("Thinking delta: +\(delta.count) chars", category: .events)
    }

    private func handleToolStart(_ event: ToolStartEvent) {
        log.info("Tool started: \(event.toolName) [\(event.toolCallId)]", category: .events)
        log.debug("Tool args: \(event.formattedArguments.prefix(200))", category: .events)

        let tool = ToolUseData(
            toolName: event.toolName,
            toolCallId: event.toolCallId,
            arguments: event.formattedArguments,
            status: .running
        )

        let message = ChatMessage(role: .assistant, content: .toolUse(tool))
        messages.append(message)
        currentToolMessages[message.id] = message
    }

    private func handleToolEnd(_ event: ToolEndEvent) {
        log.info("Tool ended: \(event.toolCallId) success=\(event.success) duration=\(event.durationMs ?? 0)ms", category: .events)
        log.debug("Tool result: \(event.displayResult.prefix(300))", category: .events)

        // Find and update the tool message
        if let index = messages.lastIndex(where: {
            if case .toolUse(let tool) = $0.content {
                return tool.toolCallId == event.toolCallId
            }
            return false
        }) {
            if case .toolUse(var tool) = messages[index].content {
                tool.status = event.success ? .success : .error
                tool.result = event.displayResult
                tool.durationMs = event.durationMs
                messages[index].content = .toolUse(tool)
            }
        } else {
            log.warning("Could not find tool message for toolCallId=\(event.toolCallId)", category: .events)
        }
    }

    private func handleTurnStart(_ event: TurnStartEvent) {
        log.info("Turn \(event.turnNumber) started", category: .events)
    }

    private func handleTurnEnd(_ event: TurnEndEvent) {
        log.info("Turn ended, tokens: in=\(event.tokenUsage?.inputTokens ?? 0) out=\(event.tokenUsage?.outputTokens ?? 0)", category: .events)

        // Update token usage on the streaming message
        if let id = streamingMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].tokenUsage = event.tokenUsage
        }

        // Accumulate token usage
        if let usage = event.tokenUsage {
            accumulatedInputTokens += usage.inputTokens
            accumulatedOutputTokens += usage.outputTokens
            totalTokenUsage = TokenUsage(
                inputTokens: accumulatedInputTokens,
                outputTokens: accumulatedOutputTokens,
                cacheReadTokens: nil,
                cacheCreationTokens: nil
            )
            log.debug("Total tokens: in=\(accumulatedInputTokens) out=\(accumulatedOutputTokens)", category: .events)
        }
    }

    private func handleComplete() {
        log.info("Agent complete, finalizing message (streamingText: \(streamingText.count) chars)", category: .events)
        // Flush any pending batched updates before finalizing
        flushPendingTextUpdates()
        isProcessing = false
        finalizeStreamingMessage()
        thinkingText = ""
        currentToolMessages.removeAll()
        // Persist messages after completion
        persistMessages()
    }

    private func handleError(_ message: String) {
        log.error("Agent error: \(message)", category: .events)
        isProcessing = false
        finalizeStreamingMessage()
        messages.append(.error(message))
        thinkingText = ""
    }

    // MARK: - Message Updates

    private func updateStreamingMessage(with content: MessageContent) {
        guard let id = streamingMessageId,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        messages[index].content = content
    }

    private func finalizeStreamingMessage() {
        guard let id = streamingMessageId,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }

        if streamingText.isEmpty {
            // Remove empty streaming message
            messages.remove(at: index)
        } else {
            // Convert streaming to final text
            messages[index].content = .text(streamingText)
            messages[index].isStreaming = false
        }

        streamingMessageId = nil
        streamingText = ""
    }

    // MARK: - Error Handling

    private func showErrorAlert(_ message: String) {
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
}
