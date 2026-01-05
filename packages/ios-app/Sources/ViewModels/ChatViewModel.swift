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

    // MARK: - Private State

    private let rpcClient: RPCClient
    private let sessionId: String
    private var cancellables = Set<AnyCancellable>()
    private var streamingMessageId: UUID?
    private var streamingText = ""
    private var currentToolMessages: [UUID: ChatMessage] = [:]
    private var accumulatedInputTokens = 0
    private var accumulatedOutputTokens = 0

    /// Track tool calls for the current turn (for persistence)
    private var currentTurnToolCalls: [ToolCallRecord] = []

    // MARK: - Performance Optimization: Batched Updates

    private var pendingTextDelta = ""
    private var textUpdateTask: Task<Void, Never>?
    private let textUpdateInterval: UInt64 = 50_000_000 // 50ms in nanoseconds

    // MARK: - Initialization

    /// Reference to EventStoreManager for event-sourced persistence
    private weak var eventStoreManager: EventStoreManager?

    /// Workspace ID for event caching
    private var workspaceId: String = ""

    /// Current turn counter
    private var currentTurn = 0

    init(rpcClient: RPCClient, sessionId: String, eventStoreManager: EventStoreManager? = nil) {
        self.rpcClient = rpcClient
        self.sessionId = sessionId
        self.eventStoreManager = eventStoreManager
        setupBindings()
        setupEventHandlers()
    }

    /// Set the event store manager reference (used when injected via environment)
    func setEventStoreManager(_ manager: EventStoreManager, workspaceId: String) {
        self.eventStoreManager = manager
        self.workspaceId = workspaceId
        loadPersistedMessages()
    }

    /// Load messages from EventDatabase via state reconstruction
    private func loadPersistedMessages() {
        guard let manager = eventStoreManager else { return }

        do {
            let state = try manager.getStateAtHead(sessionId)

            var loadedMessages: [ChatMessage] = []

            for reconstructed in state.messages {
                let role: MessageRole
                switch reconstructed.role {
                case "user": role = .user
                case "assistant": role = .assistant
                case "system": role = .system
                case "toolResult": role = .toolResult
                default: role = .assistant
                }

                // Handle content which could be a string or array of content blocks
                if let textContent = reconstructed.content as? String {
                    loadedMessages.append(ChatMessage(role: role, content: .text(textContent)))
                } else if let contentBlocks = reconstructed.content as? [[String: Any]] {
                    // Parse content blocks for text and tool_use blocks
                    var textParts: [String] = []

                    for block in contentBlocks {
                        let blockType = block["type"] as? String

                        if blockType == "text", let text = block["text"] as? String {
                            textParts.append(text)
                        } else if blockType == "tool_use" {
                            // Flush any accumulated text before the tool use
                            if !textParts.isEmpty {
                                let combinedText = textParts.joined()
                                if !combinedText.isEmpty {
                                    loadedMessages.append(ChatMessage(role: role, content: .text(combinedText)))
                                }
                                textParts = []
                            }

                            // Parse tool_use block
                            let toolName = block["name"] as? String ?? "Unknown"
                            let toolCallId = block["id"] as? String ?? UUID().uuidString

                            // Format arguments as JSON string
                            var argsString = "{}"
                            if let inputDict = block["input"] as? [String: Any],
                               let jsonData = try? JSONSerialization.data(withJSONObject: inputDict, options: [.prettyPrinted, .sortedKeys]),
                               let jsonStr = String(data: jsonData, encoding: .utf8) {
                                argsString = jsonStr
                            }

                            let tool = ToolUseData(
                                toolName: toolName,
                                toolCallId: toolCallId,
                                arguments: argsString,
                                status: .success,  // Completed tools from history are always done
                                result: nil,       // Result will be in a separate tool_result block
                                durationMs: nil
                            )
                            loadedMessages.append(ChatMessage(role: .assistant, content: .toolUse(tool)))
                        } else if blockType == "tool_result" {
                            // Tool results - update the corresponding tool message
                            let toolUseId = block["tool_use_id"] as? String ?? ""
                            var resultContent = ""

                            if let content = block["content"] as? String {
                                resultContent = content
                            } else if let contentArray = block["content"] as? [[String: Any]] {
                                // Handle array of content blocks
                                for contentBlock in contentArray {
                                    if let text = contentBlock["text"] as? String {
                                        resultContent += text
                                    }
                                }
                            }

                            // Find and update the tool message with this result
                            if let index = loadedMessages.lastIndex(where: {
                                if case .toolUse(let tool) = $0.content {
                                    return tool.toolCallId == toolUseId
                                }
                                return false
                            }) {
                                if case .toolUse(var tool) = loadedMessages[index].content {
                                    tool.result = resultContent
                                    loadedMessages[index].content = .toolUse(tool)
                                }
                            }
                        }
                    }

                    // Flush any remaining text after all blocks
                    if !textParts.isEmpty {
                        let combinedText = textParts.joined()
                        if !combinedText.isEmpty {
                            loadedMessages.append(ChatMessage(role: role, content: .text(combinedText)))
                        }
                    }
                }
            }

            messages = loadedMessages

            // Update turn counter and token usage
            currentTurn = state.turnCount
            if state.tokenUsage.inputTokens > 0 || state.tokenUsage.outputTokens > 0 {
                accumulatedInputTokens = state.tokenUsage.inputTokens
                accumulatedOutputTokens = state.tokenUsage.outputTokens
                totalTokenUsage = TokenUsage(
                    inputTokens: accumulatedInputTokens,
                    outputTokens: accumulatedOutputTokens,
                    cacheReadTokens: nil,
                    cacheCreationTokens: nil
                )
            }

            logger.info("Loaded \(messages.count) messages from EventDatabase for session \(sessionId)", category: .session)
        } catch {
            logger.error("Failed to load messages from EventDatabase: \(error.localizedDescription)", category: .session)
        }
    }

    /// Cache user message event to EventDatabase
    private func cacheUserMessageEvent(content: String) {
        guard let manager = eventStoreManager else { return }
        currentTurn += 1

        do {
            _ = try manager.cacheUserMessage(
                sessionId: sessionId,
                workspaceId: workspaceId,
                content: content,
                turn: currentTurn
            )
            logger.debug("Cached user message event for turn \(currentTurn)", category: .events)
        } catch {
            logger.error("Failed to cache user message: \(error.localizedDescription)", category: .events)
        }
    }

    /// Cache assistant message event to EventDatabase
    /// Now includes tool calls in content blocks format for full persistence
    private func cacheAssistantMessageEvent(content: String, toolCalls: [ToolCallRecord] = [], tokenUsage: TokenUsage?) {
        guard let manager = eventStoreManager else { return }

        do {
            _ = try manager.cacheAssistantMessage(
                sessionId: sessionId,
                workspaceId: workspaceId,
                content: content,
                toolCalls: toolCalls,
                turn: currentTurn,
                tokenUsage: tokenUsage,
                model: currentModel
            )
            logger.debug("Cached assistant message event for turn \(currentTurn) with \(toolCalls.count) tool calls", category: .events)
        } catch {
            logger.error("Failed to cache assistant message: \(error.localizedDescription)", category: .events)
        }
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
        logger.info("connectAndResume() called for session \(sessionId)", category: .session)

        // Connect to server
        logger.debug("Calling rpcClient.connect()...", category: .session)
        await rpcClient.connect()

        // Wait for connection
        logger.verbose("Waiting 500ms for connection to stabilize...", category: .session)
        try? await Task.sleep(for: .milliseconds(500))

        guard rpcClient.isConnected else {
            logger.warning("Failed to connect to server - rpcClient.isConnected=false", category: .session)
            return
        }
        logger.info("Connected to server successfully", category: .session)

        // Resume the session
        do {
            logger.debug("Calling resumeSession for \(sessionId)...", category: .session)
            try await rpcClient.resumeSession(sessionId: sessionId)
            logger.info("Session resumed successfully", category: .session)
        } catch {
            logger.error("Failed to resume session: \(error.localizedDescription)", category: .session)
            showErrorAlert("Failed to resume session: \(error.localizedDescription)")
            return
        }

        // Try to load message history (non-critical, may not be supported)
        do {
            logger.debug("Fetching session history...", category: .session)
            let history = try await rpcClient.getSessionHistory()
            messages = history.map { historyToMessage($0) }
            logger.info("Loaded \(history.count) messages from history", category: .session)
        } catch {
            // History fetch is optional - server may not support it
            logger.debug("Could not fetch history (may not be supported): \(error.localizedDescription)", category: .session)
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
            logger.verbose("sendMessage() called but no text or images to send", category: .chat)
            return
        }

        logger.info("Sending message: \"\(text.prefix(100))...\" with \(attachedImages.count) images", category: .chat)

        // Create user message
        if !attachedImages.isEmpty {
            let imageMessage = ChatMessage(role: .user, content: .images(attachedImages))
            messages.append(imageMessage)
            logger.debug("Added image message with \(attachedImages.count) images", category: .chat)
        }

        if !text.isEmpty {
            let userMessage = ChatMessage.user(text)
            messages.append(userMessage)
            logger.debug("Added user text message", category: .chat)

            // Cache user message event to EventDatabase
            cacheUserMessageEvent(content: text)
        }

        inputText = ""
        isProcessing = true
        thinkingText = ""

        // Create streaming placeholder
        let streamingMessage = ChatMessage.streaming()
        messages.append(streamingMessage)
        streamingMessageId = streamingMessage.id
        streamingText = ""
        logger.verbose("Created streaming placeholder message id=\(streamingMessage.id)", category: .chat)

        // Prepare image attachments
        let imageAttachments = attachedImages.map {
            ImageAttachment(data: $0.data, mimeType: $0.mimeType)
        }
        attachedImages = []
        selectedImages = []

        // Send to server
        Task {
            do {
                logger.debug("Calling rpcClient.sendPrompt()...", category: .chat)
                try await rpcClient.sendPrompt(
                    text,
                    images: imageAttachments.isEmpty ? nil : imageAttachments
                )
                logger.info("Prompt sent successfully", category: .chat)
            } catch {
                logger.error("Failed to send prompt: \(error.localizedDescription)", category: .chat)
                handleError(error.localizedDescription)
            }
        }
    }

    func abortAgent() {
        logger.info("Aborting agent...", category: .chat)
        Task {
            do {
                try await rpcClient.abortAgent()
                isProcessing = false
                finalizeStreamingMessage()
                messages.append(.system("Agent aborted"))
                logger.info("Agent aborted successfully", category: .chat)
            } catch {
                logger.error("Failed to abort agent: \(error.localizedDescription)", category: .chat)
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
        // If there's no active streaming message, create a new one
        // This happens when text arrives after tool calls
        if streamingMessageId == nil {
            let newStreamingMessage = ChatMessage.streaming()
            messages.append(newStreamingMessage)
            streamingMessageId = newStreamingMessage.id
            streamingText = ""
            logger.verbose("Created new streaming message after tool calls id=\(newStreamingMessage.id)", category: .events)
        }

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

        logger.verbose("Text delta received: +\(delta.count) chars, total: \(streamingText.count)", category: .events)
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
        logger.verbose("Thinking delta: +\(delta.count) chars", category: .events)
    }

    private func handleToolStart(_ event: ToolStartEvent) {
        logger.info("Tool started: \(event.toolName) [\(event.toolCallId)]", category: .events)
        logger.debug("Tool args: \(event.formattedArguments.prefix(200))", category: .events)

        // Finalize any current streaming text before tool starts
        // This creates separate bubbles for text before vs after tool calls
        flushPendingTextUpdates()
        finalizeStreamingMessage()

        let tool = ToolUseData(
            toolName: event.toolName,
            toolCallId: event.toolCallId,
            arguments: event.formattedArguments,
            status: .running
        )

        let message = ChatMessage(role: .assistant, content: .toolUse(tool))
        messages.append(message)
        currentToolMessages[message.id] = message

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: event.toolCallId,
            toolName: event.toolName,
            arguments: event.formattedArguments
        )
        currentTurnToolCalls.append(record)
    }

    private func handleToolEnd(_ event: ToolEndEvent) {
        logger.info("Tool ended: \(event.toolCallId) success=\(event.success) duration=\(event.durationMs ?? 0)ms", category: .events)
        logger.debug("Tool result: \(event.displayResult.prefix(300))", category: .events)

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
            logger.warning("Could not find tool message for toolCallId=\(event.toolCallId)", category: .events)
        }

        // Update tracked tool call with result for persistence
        if let idx = currentTurnToolCalls.firstIndex(where: { $0.toolCallId == event.toolCallId }) {
            currentTurnToolCalls[idx].result = event.displayResult
            currentTurnToolCalls[idx].isError = !event.success
        }
    }

    private func handleTurnStart(_ event: TurnStartEvent) {
        logger.info("Turn \(event.turnNumber) started", category: .events)
    }

    private func handleTurnEnd(_ event: TurnEndEvent) {
        logger.info("Turn ended, tokens: in=\(event.tokenUsage?.inputTokens ?? 0) out=\(event.tokenUsage?.outputTokens ?? 0)", category: .events)

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
            logger.debug("Total tokens: in=\(accumulatedInputTokens) out=\(accumulatedOutputTokens)", category: .events)
        }
    }

    private func handleComplete() {
        logger.info("Agent complete, finalizing message (streamingText: \(streamingText.count) chars, toolCalls: \(currentTurnToolCalls.count))", category: .events)
        // Flush any pending batched updates before finalizing
        flushPendingTextUpdates()

        // Cache assistant message event with tool calls before finalizing
        if !streamingText.isEmpty || !currentTurnToolCalls.isEmpty {
            cacheAssistantMessageEvent(
                content: streamingText,
                toolCalls: currentTurnToolCalls,
                tokenUsage: totalTokenUsage
            )
        }

        isProcessing = false
        finalizeStreamingMessage()
        thinkingText = ""
        currentToolMessages.removeAll()
        currentTurnToolCalls.removeAll()  // Clear tool calls for next turn
    }

    private func handleError(_ message: String) {
        logger.error("Agent error: \(message)", category: .events)
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

    /// Estimated context usage percentage based on total tokens and model context window
    var contextPercentage: Int {
        guard let usage = totalTokenUsage else { return 0 }

        // Get context window for current model
        let contextWindow = modelContextWindow(for: currentModel)
        guard contextWindow > 0 else { return 0 }

        // Total tokens used (input + output counts toward context)
        let totalUsed = usage.inputTokens + usage.outputTokens
        let percentage = Double(totalUsed) / Double(contextWindow) * 100

        return min(100, Int(percentage.rounded()))
    }

    /// Returns the context window size for a given model ID
    private func modelContextWindow(for modelId: String) -> Int {
        let lowered = modelId.lowercased()

        // Claude 4.5 models have 200k context
        if lowered.contains("4-5") || lowered.contains("4.5") {
            return 200_000
        }

        // Claude 4 models have 200k context
        if lowered.contains("-4-") || lowered.contains("sonnet-4") || lowered.contains("opus-4") {
            return 200_000
        }

        // Claude 3.5 models have 200k context
        if lowered.contains("3-5") || lowered.contains("3.5") {
            return 200_000
        }

        // Default to 200k for safety
        return 200_000
    }
}
