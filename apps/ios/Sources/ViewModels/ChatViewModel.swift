import SwiftUI
import Combine
import os
import PhotosUI

// MARK: - Chat View Model

@MainActor
class ChatViewModel: ObservableObject {
    private let logger = Logger(subsystem: "com.tron.mobile", category: "ChatViewModel")

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    @Published var inputText = ""
    @Published var isProcessing = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var showSettings = false
    @Published var showSessionList = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var selectedImages: [PhotosPickerItem] = []
    @Published var attachedImages: [ImageContent] = []
    @Published var thinkingText = ""
    @Published var isThinkingExpanded = false

    // MARK: - Private State

    private let rpcClient: RPCClient
    private var cancellables = Set<AnyCancellable>()
    private var streamingMessageId: UUID?
    private var streamingText = ""
    private var currentToolMessages: [UUID: ChatMessage] = [:]

    // MARK: - Initialization

    init(rpcClient: RPCClient) {
        self.rpcClient = rpcClient
        setupBindings()
        setupEventHandlers()
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

    // MARK: - Connection

    func connect() async {
        await rpcClient.connect()
    }

    func disconnect() async {
        await rpcClient.disconnect()
    }

    // MARK: - Session Management

    func createNewSession(workingDirectory: String) async {
        do {
            let result = try await rpcClient.createSession(workingDirectory: workingDirectory)
            messages = []
            messages.append(.system("Session created: \(result.sessionId.prefix(8))... using \(result.model)"))
        } catch {
            showErrorAlert(error.localizedDescription)
        }
    }

    func resumeSession(_ session: SessionInfo) async {
        do {
            try await rpcClient.resumeSession(sessionId: session.sessionId)

            // Load history
            let history = try await rpcClient.getSessionHistory()
            messages = history.map { historyToMessage($0) }

            showSessionList = false
        } catch {
            showErrorAlert(error.localizedDescription)
        }
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
        guard !text.isEmpty || !attachedImages.isEmpty else { return }

        // Create user message
        if !attachedImages.isEmpty {
            let imageMessage = ChatMessage(role: .user, content: .images(attachedImages))
            messages.append(imageMessage)
        }

        if !text.isEmpty {
            let userMessage = ChatMessage.user(text)
            messages.append(userMessage)
        }

        inputText = ""
        isProcessing = true
        thinkingText = ""

        // Create streaming placeholder
        let streamingMessage = ChatMessage.streaming()
        messages.append(streamingMessage)
        streamingMessageId = streamingMessage.id
        streamingText = ""

        // Prepare image attachments
        let imageAttachments = attachedImages.map {
            ImageAttachment(data: $0.data, mimeType: $0.mimeType)
        }
        attachedImages = []
        selectedImages = []

        // Send to server
        Task {
            do {
                try await rpcClient.sendPrompt(
                    text,
                    images: imageAttachments.isEmpty ? nil : imageAttachments
                )
            } catch {
                handleError(error.localizedDescription)
            }
        }
    }

    func abortAgent() {
        Task {
            do {
                try await rpcClient.abortAgent()
                isProcessing = false
                finalizeStreamingMessage()
                messages.append(.system("Agent aborted"))
            } catch {
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
        streamingText += delta
        updateStreamingMessage(with: .streaming(streamingText))
    }

    private func handleThinkingDelta(_ delta: String) {
        thinkingText += delta
    }

    private func handleToolStart(_ event: ToolStartEvent) {
        let tool = ToolUseContent(
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
        }
    }

    private func handleTurnStart(_ event: TurnStartEvent) {
        logger.debug("Turn \(event.turnNumber) started")
    }

    private func handleTurnEnd(_ event: TurnEndEvent) {
        // Update token usage on the streaming message
        if let id = streamingMessageId,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].tokenUsage = event.tokenUsage
        }
    }

    private func handleComplete() {
        isProcessing = false
        finalizeStreamingMessage()
        thinkingText = ""
        currentToolMessages.removeAll()
    }

    private func handleError(_ message: String) {
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
