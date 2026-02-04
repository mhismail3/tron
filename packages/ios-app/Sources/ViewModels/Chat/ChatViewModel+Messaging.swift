import SwiftUI
import PhotosUI

// MARK: - MessagingContext Conformance

extension ChatViewModel: MessagingContext {
    var autoDismissedBrowserThisTurn: Bool {
        get { browserState.autoDismissedBrowserThisTurn }
        set { browserState.autoDismissedBrowserThisTurn = newValue }
    }

    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?,
        spells: [Skill]?
    ) async throws {
        try await rpcClient.agent.sendPrompt(
            text,
            images: nil,  // Images sent via attachments instead
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            skills: skills,
            spells: spells
        )
    }

    func abortAgentOnServer() async throws {
        try await rpcClient.agent.abort()
    }

    func appendInterruptedMessage() {
        messages.append(.interrupted())
    }

    func finalizeThinkingMessage() {
        markThinkingMessageCompleteIfNeeded()
    }

    func clearThinkingCaption() {
        thinkingState.clearCurrentStreaming()
    }

    // Note: The following methods are already defined in other extensions:
    // - resetStreamingManager() in ChatViewModel+TurnLifecycleContext.swift
    // - setSessionProcessing(_:) in ChatViewModel+TurnLifecycleContext.swift
    // - handleAgentError(_:) in ChatViewModel+Events.swift
    // - logVerbose(_:) in ChatViewModel+UICanvasContext.swift
    // - logDebug/Info/Warning/Error in ChatViewModel.swift
    // MessagingContext conformance uses those existing implementations.

    func updateSessionDashboardInfo(lastUserPrompt: String?, lastAssistantResponse: String?) {
        if let prompt = lastUserPrompt {
            eventStoreManager?.updateSessionDashboardInfo(sessionId: sessionId, lastUserPrompt: prompt)
        }
        if let response = lastAssistantResponse {
            eventStoreManager?.updateSessionDashboardInfo(sessionId: sessionId, lastAssistantResponse: response)
        }
    }

    /// Dismiss any pending subagent results.
    /// Called when user sends a different message (not via the "Send" button).
    /// This is a one-time shortcut - if they choose to continue the conversation
    /// with their own prompt, they lose the ability to auto-send subagent results.
    func dismissPendingSubagentResults() {
        let pendingIds = subagentState.allSubagentsSorted
            .filter { $0.resultDeliveryStatus == .pending }
            .map { $0.subagentSessionId }

        for sessionId in pendingIds {
            subagentState.markResultsDismissed(subagentSessionId: sessionId)
            logger.debug("Dismissed pending subagent result: \(sessionId)", category: .chat)
        }

        if !pendingIds.isEmpty {
            logger.info("Dismissed \(pendingIds.count) pending subagent result(s) - user sent different message", category: .chat)
        }
    }
}

// MARK: - Message Sending & Image Handling

extension ChatViewModel {

    /// Send a message to the agent
    func sendMessage(reasoningLevel: String? = nil, skills: [Skill]? = nil, spells: [Skill]? = nil) {
        Task {
            await messagingCoordinator.sendMessage(
                reasoningLevel: reasoningLevel,
                skills: skills,
                spells: spells,
                context: self
            )
        }
    }

    /// Abort the currently running agent
    func abortAgent() {
        Task {
            await messagingCoordinator.abortAgent(context: self)
        }
    }

    // MARK: - Image Handling

    func processSelectedImages(_ items: [PhotosPickerItem]) async {
        for item in items {
            // Load the image data
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                continue
            }

            // Compress the image (same as camera photos)
            guard let result = await ImageCompressor.compress(uiImage) else {
                logger.warning("Failed to compress library image", category: .chat)
                continue
            }

            // Create unified Attachment (same model as camera photos)
            let attachment = Attachment(
                type: .image,
                data: result.data,
                mimeType: result.mimeType,
                fileName: nil,
                originalSize: data.count
            )

            await MainActor.run {
                self.attachments.append(attachment)
            }
        }

        // Clear the picker selection
        await MainActor.run {
            self.selectedImages = []
        }
    }

    // MARK: - Unified Attachment Handling

    func addAttachment(_ attachment: Attachment) {
        messagingCoordinator.addAttachment(attachment, context: self)
    }

    func removeAttachment(_ attachment: Attachment) {
        messagingCoordinator.removeAttachment(attachment, context: self)
    }
}
