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
    /// Whether more older messages are available for loading
    @Published var hasMoreMessages = false
    /// Whether currently loading more messages
    @Published var isLoadingMoreMessages = false

    // MARK: - Private State

    private let rpcClient: RPCClient
    private let sessionId: String
    private var cancellables = Set<AnyCancellable>()
    private var streamingMessageId: UUID?
    private var streamingText = ""
    private var currentToolMessages: [UUID: ChatMessage] = [:]
    private var accumulatedInputTokens = 0
    private var accumulatedOutputTokens = 0

    /// Track tool calls for the current turn (for display purposes)
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

    // MARK: - Pagination State

    /// All loaded messages from EventDatabase (full set for pagination)
    private var allReconstructedMessages: [ChatMessage] = []
    /// Number of messages to show initially
    private static let initialMessageBatchSize = 50
    /// Number of messages to load on scroll-up
    private static let additionalMessageBatchSize = 30
    /// Current number of messages displayed (from the end)
    private var displayedMessageCount = 0
    /// Whether initial history has been loaded (prevents redundant loads on view re-entry)
    private var hasInitiallyLoaded = false

    init(rpcClient: RPCClient, sessionId: String, eventStoreManager: EventStoreManager? = nil) {
        self.rpcClient = rpcClient
        self.sessionId = sessionId
        self.eventStoreManager = eventStoreManager
        setupBindings()
        setupEventHandlers()
    }

    /// Set the event store manager reference (used when injected via environment)
    /// This method is async and should be awaited to ensure history is fully loaded
    /// before allowing user interaction (prevents race conditions with streaming)
    func setEventStoreManager(_ manager: EventStoreManager, workspaceId: String) async {
        self.eventStoreManager = manager
        self.workspaceId = workspaceId
        // Sync from server first (to get any events that happened while we were away),
        // then load persisted messages - awaited to prevent race conditions
        await syncAndLoadMessages()
    }

    /// Sync events from server, then load messages from local database
    /// This ensures we see events that happened while we were away from this session
    private func syncAndLoadMessages() async {
        guard let manager = eventStoreManager else { return }

        // Skip if already loaded and we have messages (re-entering view after navigation)
        // The streaming guard in loadPersistedMessagesAsync handles the mid-stream case
        if hasInitiallyLoaded && !messages.isEmpty && !isProcessing {
            logger.info("Skipping redundant sync/load - already have \(messages.count) messages", category: .session)
            return
        }

        // First sync from server to get any events that happened while we were away
        do {
            try await manager.syncSessionEvents(sessionId: sessionId)
            logger.info("Synced events from server before loading messages", category: .session)
        } catch {
            // Don't fail - we can still show what we have locally
            logger.warning("Failed to sync events from server: \(error.localizedDescription)", category: .session)
        }

        // Now load from local database (which now includes synced events)
        await loadPersistedMessagesAsync()
        hasInitiallyLoaded = true
    }

    /// Load messages from EventDatabase asynchronously to avoid blocking UI
    private func loadPersistedMessagesAsync() async {
        guard let manager = eventStoreManager else { return }

        // Don't replace messages if actively streaming - user is in the middle of a turn
        // This protects mid-stream content that hasn't been persisted to event store yet
        if isProcessing || streamingMessageId != nil {
            logger.info("Skipping history load - streaming in progress, preserving current content", category: .session)
            return
        }

        // Yield to let UI render first
        await Task.yield()

        do {
            let state = try manager.getStateAtHead(sessionId)

            // Process messages with periodic yields to keep UI responsive
            var loadedMessages: [ChatMessage] = []
            var messageCount = 0

            for reconstructed in state.messages {
                messageCount += 1
                // Yield every 10 messages to allow UI updates
                if messageCount % 10 == 0 {
                    await Task.yield()
                }

                let role: MessageRole
                switch reconstructed.role {
                case "user": role = .user
                case "assistant": role = .assistant
                case "system": role = .system
                case "toolResult": role = .toolResult
                default: role = .assistant
                }

                // Handle content which could be a string or array of content blocks
                logger.debug("[DEBUG] ChatVM loadPersisted: role=\(reconstructed.role) content type=\(type(of: reconstructed.content))", category: .session)
                if let textContent = reconstructed.content as? String {
                    logger.debug("[DEBUG] ChatVM: parsed as String, length: \(textContent.count)", category: .session)
                    // Create message with enriched metadata (for assistant messages)
                    loadedMessages.append(ChatMessage(
                        role: role,
                        content: .text(textContent),
                        tokenUsage: reconstructed.tokenUsage,
                        model: reconstructed.model,
                        latencyMs: reconstructed.latencyMs,
                        turnNumber: reconstructed.turnNumber,
                        hasThinking: reconstructed.hasThinking,
                        stopReason: reconstructed.stopReason
                    ))
                } else if let contentBlocks = convertToContentBlocks(reconstructed.content) {
                    logger.debug("[DEBUG] ChatVM: parsed as content blocks, count: \(contentBlocks.count)", category: .session)
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
                                    // Create message with enriched metadata (for assistant messages)
                                    loadedMessages.append(ChatMessage(
                                        role: role,
                                        content: .text(combinedText),
                                        tokenUsage: reconstructed.tokenUsage,
                                        model: reconstructed.model,
                                        latencyMs: reconstructed.latencyMs,
                                        turnNumber: reconstructed.turnNumber,
                                        hasThinking: reconstructed.hasThinking,
                                        stopReason: reconstructed.stopReason
                                    ))
                                }
                                textParts = []
                            }

                            // Parse tool_use block
                            let toolName = block["name"] as? String ?? "Unknown"
                            let toolCallId = block["id"] as? String ?? UUID().uuidString

                            // Format arguments as JSON string - handle multiple possible types
                            var argsString = "{}"
                            let inputValue = block["input"]
                            logger.debug("[DEBUG] tool_use '\(toolName)' input type: \(type(of: inputValue as Any))", category: .session)

                            if let inputDict = inputValue as? [String: Any] {
                                if let jsonData = try? JSONSerialization.data(withJSONObject: inputDict, options: [.prettyPrinted, .sortedKeys]),
                                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                                    argsString = jsonStr
                                }
                            } else if let inputDict = inputValue as? [String: AnyCodable] {
                                // Handle case where AnyCodable wraps nested dictionaries
                                let unwrapped = inputDict.mapValues { $0.value }
                                if let jsonData = try? JSONSerialization.data(withJSONObject: unwrapped, options: [.prettyPrinted, .sortedKeys]),
                                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                                    argsString = jsonStr
                                }
                            }
                            logger.debug("[DEBUG] tool_use '\(toolName)' argsString: \(argsString.prefix(100))", category: .session)

                            let tool = ToolUseData(
                                toolName: toolName,
                                toolCallId: toolCallId,
                                arguments: argsString,
                                status: .success,
                                result: nil,
                                durationMs: nil
                            )
                            loadedMessages.append(ChatMessage(role: .assistant, content: .toolUse(tool)))
                        } else if blockType == "tool_result" {
                            // Tool results - update the corresponding tool message
                            let toolUseId = block["tool_use_id"] as? String ?? ""
                            logger.debug("[DEBUG] tool_result for '\(toolUseId)', content type: \(type(of: block["content"] as Any))", category: .session)
                            var resultContent = ""

                            if let content = block["content"] as? String {
                                resultContent = content
                            } else if let contentArray = block["content"] as? [[String: Any]] {
                                for contentBlock in contentArray {
                                    if let text = contentBlock["text"] as? String {
                                        resultContent += text
                                    }
                                }
                            }
                            logger.debug("[DEBUG] tool_result content length: \(resultContent.count)", category: .session)

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
                            // Create message with enriched metadata (for assistant messages)
                            loadedMessages.append(ChatMessage(
                                role: role,
                                content: .text(combinedText),
                                tokenUsage: reconstructed.tokenUsage,
                                model: reconstructed.model,
                                latencyMs: reconstructed.latencyMs,
                                turnNumber: reconstructed.turnNumber,
                                hasThinking: reconstructed.hasThinking,
                                stopReason: reconstructed.stopReason
                            ))
                        }
                    }
                } else {
                    logger.warning("[DEBUG] ChatVM: content was neither String nor convertible to blocks! type=\(type(of: reconstructed.content))", category: .session)
                }
            }

            // Store all messages for pagination
            allReconstructedMessages = loadedMessages

            // Show only the latest batch of messages (like iOS Messages app)
            let batchSize = min(Self.initialMessageBatchSize, loadedMessages.count)
            displayedMessageCount = batchSize
            hasMoreMessages = loadedMessages.count > batchSize

            if batchSize > 0 {
                let startIndex = loadedMessages.count - batchSize
                messages = Array(loadedMessages[startIndex...])
            } else {
                messages = []
            }

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

            logger.info("Loaded \(loadedMessages.count) messages, displaying latest \(batchSize) for session \(sessionId)", category: .session)
        } catch {
            logger.error("Failed to load messages from EventDatabase: \(error.localizedDescription)", category: .session)
        }
    }

    /// Load more older messages when user scrolls to top (like iOS Messages)
    /// This prepends historical messages from the initial load snapshot
    func loadMoreMessages() {
        guard hasMoreMessages, !isLoadingMoreMessages else { return }

        isLoadingMoreMessages = true

        // Calculate how many historical messages we haven't shown yet
        let historicalCount = allReconstructedMessages.count
        let shownFromHistory = displayedMessageCount

        // How many more to load from history
        let remainingInHistory = historicalCount - shownFromHistory
        let batchToLoad = min(Self.additionalMessageBatchSize, remainingInHistory)

        if batchToLoad > 0 {
            // Get the next batch of older messages (from the end of unshown portion)
            let endIndex = historicalCount - shownFromHistory
            let startIndex = max(0, endIndex - batchToLoad)
            let olderMessages = Array(allReconstructedMessages[startIndex..<endIndex])

            // Prepend to current messages
            messages.insert(contentsOf: olderMessages, at: 0)
            displayedMessageCount += batchToLoad

            logger.debug("Loaded \(batchToLoad) more messages, now showing \(displayedMessageCount) historical + new", category: .session)
        }

        hasMoreMessages = displayedMessageCount < historicalCount
        isLoadingMoreMessages = false
    }

    /// Append a new message to the display (streaming messages during active session)
    /// Note: Historical messages are in allReconstructedMessages; this is for new messages only
    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        // Don't add to allReconstructedMessages - that's the historical snapshot
        // New messages are persisted via EventDatabase and will be in the snapshot next session
    }

    /// Load messages from EventDatabase via state reconstruction (sync version - kept for compatibility)
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
                    // Create message with enriched metadata (for assistant messages)
                    loadedMessages.append(ChatMessage(
                        role: role,
                        content: .text(textContent),
                        tokenUsage: reconstructed.tokenUsage,
                        model: reconstructed.model,
                        latencyMs: reconstructed.latencyMs,
                        turnNumber: reconstructed.turnNumber,
                        hasThinking: reconstructed.hasThinking,
                        stopReason: reconstructed.stopReason
                    ))
                } else if let contentBlocks = convertToContentBlocks(reconstructed.content) {
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
                                    // Create message with enriched metadata (for assistant messages)
                                    loadedMessages.append(ChatMessage(
                                        role: role,
                                        content: .text(combinedText),
                                        tokenUsage: reconstructed.tokenUsage,
                                        model: reconstructed.model,
                                        latencyMs: reconstructed.latencyMs,
                                        turnNumber: reconstructed.turnNumber,
                                        hasThinking: reconstructed.hasThinking,
                                        stopReason: reconstructed.stopReason
                                    ))
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
                            // Create message with enriched metadata (for assistant messages)
                            loadedMessages.append(ChatMessage(
                                role: role,
                                content: .text(combinedText),
                                tokenUsage: reconstructed.tokenUsage,
                                model: reconstructed.model,
                                latencyMs: reconstructed.latencyMs,
                                turnNumber: reconstructed.turnNumber,
                                hasThinking: reconstructed.hasThinking,
                                stopReason: reconstructed.stopReason
                            ))
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

        rpcClient.onAgentTurn = { [weak self] event in
            self?.handleAgentTurn(event)
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

        // Only wait if not already connected (avoid unnecessary delay)
        if !rpcClient.isConnected {
            logger.verbose("Waiting briefly for connection...", category: .session)
            try? await Task.sleep(for: .milliseconds(100))
        }

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

        // NOTE: We intentionally do NOT fetch server history here.
        // The local EventDatabase is the source of truth for message history,
        // and it contains full content blocks (including tool calls and results).
        // Server history is text-only and would lose tool call information.
        // Messages are loaded via setEventStoreManager() -> loadPersistedMessagesAsync()
        logger.debug("Session resumed, using local EventDatabase for message history", category: .session)
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

    /// Safely convert Any to content blocks array.
    /// Handles JSON type erasure where arrays become [Any] instead of [[String: Any]].
    /// Also handles NSArray from Objective-C bridging.
    private func convertToContentBlocks(_ value: Any) -> [[String: Any]]? {
        logger.debug("[DEBUG] convertToContentBlocks: input type=\(type(of: value))", category: .session)

        // Direct cast (works if already properly typed)
        if let blocks = value as? [[String: Any]] {
            logger.debug("[DEBUG] convertToContentBlocks: direct cast to [[String: Any]] succeeded, \(blocks.count) blocks", category: .session)
            return blocks
        }

        // Handle [Any] arrays (common after JSON decoding)
        if let anyArray = value as? [Any] {
            logger.debug("[DEBUG] convertToContentBlocks: cast to [Any] succeeded, \(anyArray.count) elements", category: .session)
            var result: [[String: Any]] = []
            for (idx, element) in anyArray.enumerated() {
                logger.debug("[DEBUG] convertToContentBlocks: element[\(idx)] type=\(type(of: element))", category: .session)
                if let dict = element as? [String: Any] {
                    result.append(dict)
                }
            }
            // Only return if we successfully converted all elements
            if !result.isEmpty {
                logger.debug("[DEBUG] convertToContentBlocks: converted to \(result.count) blocks", category: .session)
                return result
            }
        }

        // Handle NSArray (Objective-C bridging)
        if let nsArray = value as? NSArray {
            var result: [[String: Any]] = []
            for element in nsArray {
                if let dict = element as? [String: Any] {
                    result.append(dict)
                } else if let nsDict = element as? NSDictionary as? [String: Any] {
                    result.append(nsDict)
                }
            }
            if !result.isEmpty {
                return result
            }
        }

        logger.warning("[DEBUG] convertToContentBlocks: all conversion attempts failed for type \(type(of: value))", category: .session)
        return nil
    }

    // MARK: - Message Sending

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else {
            logger.verbose("sendMessage() called but no text or images to send", category: .chat)
            return
        }

        logger.info("Sending message: \"\(text.prefix(100))...\" with \(attachedImages.count) images", category: .chat)

        // Create user message (use appendMessage to keep pagination in sync)
        if !attachedImages.isEmpty {
            let imageMessage = ChatMessage(role: .user, content: .images(attachedImages))
            appendMessage(imageMessage)
            logger.debug("Added image message with \(attachedImages.count) images", category: .chat)
        }

        if !text.isEmpty {
            let userMessage = ChatMessage.user(text)
            appendMessage(userMessage)
            logger.debug("Added user text message", category: .chat)
            currentTurn += 1
            // Note: We don't cache user message locally - server is source of truth
            // After turn completes, we sync from server to get authoritative events
        }

        inputText = ""
        isProcessing = true
        thinkingText = ""

        // Update dashboard processing state
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: true)
        // Update dashboard with the prompt we just sent
        eventStoreManager?.updateSessionDashboardInfo(sessionId: sessionId, lastUserPrompt: text)

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
                eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
                eventStoreManager?.updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: "Interrupted"
                )
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

        // Track tool call for persistence (will be added to content items when complete)
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

        // Update tracked tool call with result (for display tracking)
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

        // Update token usage, model, and latency on the streaming message
        if let id = streamingMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].tokenUsage = event.tokenUsage
            messages[index].model = currentModel
            messages[index].latencyMs = event.data?.duration
            messages[index].stopReason = event.stopReason
            messages[index].turnNumber = event.turnNumber
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

    private func handleAgentTurn(_ event: AgentTurnEvent) {
        logger.info("Agent turn received: \(event.messages.count) messages, \(event.toolUses.count) tool uses, \(event.toolResults.count) tool results", category: .events)

        // Cache the full turn content to EventStoreManager
        // This captures tool_use and tool_result blocks that may not be in server events
        guard let manager = eventStoreManager else {
            logger.warning("No EventStoreManager to cache agent turn content", category: .events)
            return
        }

        // Convert AgentTurnEvent messages to cacheable format
        var turnMessages: [[String: Any]] = []
        for msg in event.messages {
            var messageDict: [String: Any] = ["role": msg.role]

            // Convert content to proper format
            switch msg.content {
            case .text(let text):
                messageDict["content"] = text
            case .blocks(let blocks):
                var contentBlocks: [[String: Any]] = []
                for block in blocks {
                    switch block {
                    case .text(let text):
                        contentBlocks.append(["type": "text", "text": text])
                    case .toolUse(let id, let name, let input):
                        var inputDict: [String: Any] = [:]
                        for (key, value) in input {
                            inputDict[key] = value.value
                        }
                        contentBlocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": inputDict
                        ])
                    case .toolResult(let toolUseId, let content, let isError):
                        contentBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": toolUseId,
                            "content": content,
                            "is_error": isError
                        ])
                    case .thinking(let text):
                        contentBlocks.append(["type": "thinking", "thinking": text])
                    case .unknown:
                        break
                    }
                }
                messageDict["content"] = contentBlocks
            }
            turnMessages.append(messageDict)
        }

        // Cache the turn content for merging with server events
        manager.cacheTurnContent(
            sessionId: sessionId,
            turnNumber: event.turnNumber,
            messages: turnMessages
        )

        // Now trigger sync AFTER caching content
        // This ensures the cache is populated before enrichment happens
        logger.info("Triggering sync after caching agent turn content", category: .events)
        Task {
            await syncSessionEventsFromServer()
        }
    }

    private func handleComplete() {
        logger.info("Agent complete, finalizing message (streamingText: \(streamingText.count) chars, toolCalls: \(currentTurnToolCalls.count))", category: .events)
        // Flush any pending batched updates before finalizing
        flushPendingTextUpdates()

        isProcessing = false
        finalizeStreamingMessage()
        thinkingText = ""

        // Update dashboard with final response and tool count
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: streamingText.isEmpty ? nil : String(streamingText.prefix(200)),
            lastToolCount: currentTurnToolCalls.isEmpty ? nil : currentTurnToolCalls.count
        )

        currentToolMessages.removeAll()
        currentTurnToolCalls.removeAll()  // Clear tool calls for next turn

        // NOTE: We do NOT sync from server here anymore.
        // The sync is triggered from handleAgentTurn which arrives AFTER agent.complete
        // and contains the full message content including tool blocks.
        // This ensures the cache is populated before syncing.
    }

    /// Sync session events from server after turn completes
    /// This ensures the local EventDatabase has authoritative server events
    private func syncSessionEventsFromServer() async {
        guard let manager = eventStoreManager else {
            logger.warning("No EventStoreManager available for sync", category: .events)
            return
        }

        do {
            try await manager.syncSessionEvents(sessionId: sessionId)
            logger.info("Synced session events from server for session \(sessionId)", category: .events)
        } catch {
            logger.error("Failed to sync session events: \(error.localizedDescription)", category: .events)
        }
    }

    private func handleError(_ message: String) {
        logger.error("Agent error: \(message)", category: .events)
        isProcessing = false
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
        eventStoreManager?.updateSessionDashboardInfo(
            sessionId: sessionId,
            lastAssistantResponse: "Error: \(String(message.prefix(100)))"
        )
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
