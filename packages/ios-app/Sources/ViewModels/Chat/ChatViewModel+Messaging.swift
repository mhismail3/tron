import SwiftUI
import PhotosUI

// MARK: - MessagingContext Conformance

extension ChatViewModel: MessagingContext {

    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        try await engineClient.agent.sendPrompt(
            text,
            images: nil,  // Images sent via attachments instead
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            idempotencyKey: idempotencyKey
        )
    }

    func ensureLiveEventSubscription() async throws {
        logger.info("Ensuring live engine event subscription before prompt send", category: .events)
        try await engineClient.ensureSessionEventSubscription(sessionId: sessionId, workspaceId: nil)
    }

    func abortAgentOnServer(idempotencyKey: EngineIdempotencyKey) async throws {
        try await engineClient.agent.abort(idempotencyKey: idempotencyKey)
    }

    func appendInterruptedMessage() {
        appendToMessages(.interrupted())
    }

    func finalizeThinkingMessage() {
        markThinkingMessageCompleteIfNeeded()
    }

    func clearThinkingCaption() {
        thinkingState.clearCurrentStreaming()
    }

    func markAwaitingSuggestions() {
        pullUpPanelState.awaitingSuggestions = true
    }

    // Note: The following methods are already defined in other extensions:
    // - resetStreamingManager() in ChatViewModel+TurnLifecycleContext.swift
    // - setSessionProcessing(_:) in ChatViewModel+TurnLifecycleContext.swift
    // - handleAgentError(_:) in ChatViewModel+Events.swift
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

}

// MARK: - Message Sending & Image Handling

extension ChatViewModel {

    /// Send a message to the agent.
    func sendMessage(reasoningLevel: String? = nil) {
        Task {
            await messagingCoordinator.sendMessage(
                reasoningLevel: reasoningLevel,
                context: self
            )
        }
    }

    /// Abort the currently running agent.
    /// If the message queue has items, shows a confirmation dialog instead.
    func abortAgent() {
        if messageQueueState.hasMessages {
            showAbortConfirmation = true
        } else {
            Task { await messagingCoordinator.abortAgent(context: self) }
        }
    }

    /// Cooperatively abort a single in-flight capability invocation without stopping the turn.
    /// The server cancels the per-invocation CancellationToken so the capability can observe
    /// cancellation and return an error result; the agent loop continues.
    func abortCapabilityInvocation(invocationId: String, idempotencyKey: EngineIdempotencyKey) {
        Task {
            do {
                _ = try await engineClient.agent.abortCapabilityInvocation(invocationId: invocationId, idempotencyKey: idempotencyKey)
            } catch {
                logError("Failed to abort capability \(invocationId): \(error.localizedDescription)")
            }
        }
    }

    /// Abort and discard all queued messages (server-side clear).
    func abortAndClearQueue() {
        Task {
            await messagingCoordinator.abortAgent(context: self)
            do {
                try await engineClient.agent.clearQueue(idempotencyKey: .userAction("agent.clearQueue"))
            } catch {
                logError("Failed to clear queue: \(error.localizedDescription)")
            }
        }
    }

    /// Abort but keep queued messages — server auto-drains on next agent.ready.
    func abortKeepQueue() {
        Task {
            await messagingCoordinator.abortAgent(context: self)
        }
    }

    // MARK: - Retry Turn (C7)

    /// Re-issue the most recent user text prompt after a recoverable turn
    /// failure (C7). Called when the user taps the "Retry" button on a
    /// `turn.failed` notification.
    ///
    /// Semantics:
    /// - Walks `messages` in reverse looking for the newest `role == .user`
    ///   message with `.text(…)` content.
    /// - If found, calls `engineClient.agent.sendPrompt` with that text and
    ///   the message's original attachments; the server emits a fresh
    ///   `message.user` event and starts a new turn.
    /// - If not found (empty history, or last user message is an image-only
    ///   attachment with no text), surfaces a user-visible error rather
    ///   than silently no-op'ing. Image-only retry would require
    ///   re-uploading binary content we no longer hold, so we ask the user
    ///   to re-compose.
    ///
    /// Limitation: the retry targets the LATEST user prompt, not the prompt
    /// that failed. If the user queued a second prompt after the failed one,
    /// this retries the second. In practice the send button is disabled
    /// during a failed turn until the retry lands, so this is rarely
    /// ambiguous — but we call it out here for future callers.
    func retryLastTurn() {
        guard let lastUserMessage = findLastUserTextMessage() else {
            logError("Retry requested but no user text message found in history")
            showError("Cannot retry: no previous message to re-send. Please type your message again.")
            return
        }

        guard case .text(let prompt) = lastUserMessage.content, !prompt.isEmpty else {
            // Defensive — findLastUserTextMessage already filters to .text
            logError("Retry found a user message but its content was not plain text")
            showError("Cannot retry: the previous message was not a text prompt.")
            return
        }

        logInfo("Retrying last turn (\"\(prompt.prefix(50))...\")")

        let fileAttachments: [FileAttachment]? = lastUserMessage.attachments?.map { attachment in
            FileAttachment(attachment: attachment)
        }

        Task {
            do {
                try await sendPromptToServer(
                    text: prompt,
                    attachments: fileAttachments,
                    reasoningLevel: nil,
                    idempotencyKey: .userAction("agent.prompt.retry")
                )
            } catch {
                logError("Retry failed: \(error.localizedDescription)")
                showError("Could not retry: \(error.localizedDescription)")
            }
        }
    }

    /// Walk `messages` from newest to oldest returning the first user
    /// message whose content is plain text. Used by `retryLastTurn`.
    ///
    /// Internal rather than private so unit tests (C7) can directly verify
    /// the traversal order, skip semantics, and "no text prompt" result
    /// without needing to wire a mock engine client.
    func findLastUserTextMessage() -> ChatMessage? {
        for message in messages.reversed() where message.role == .user {
            if case .text = message.content {
                return message
            }
        }
        return nil
    }

    // MARK: - Message Queue (Server-Driven)

    /// Queue the current input text on the server for delivery when the agent becomes ready.
    /// The server persists a `message.queued` event and broadcasts it — the pill appears
    /// when the `MessageQueuedPlugin` event arrives via WebSocket.
    func enqueueCurrentInput() {
        let text = inputBarState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputBarState.text = ""
        Task {
            do {
                _ = try await engineClient.agent.queuePrompt(text, idempotencyKey: .userAction("agent.queuePrompt"))
                logInfo("Queued message on server: \"\(text.prefix(50))...\"")
            } catch {
                logError("Failed to queue message: \(error.localizedDescription)")
                // Restore text so user doesn't lose their input
                inputBarState.text = text
                showError("Could not queue message: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Image Handling

    func processSelectedImages(_ items: [PhotosPickerItem]) async {
        for item in items {
            // Load the image data
            guard let data = try? await item.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil else {
                continue
            }

            // Process image with provider-aware limits, preserving format
            let detectedMime = ImageProcessor.detectMimeType(from: data)
            let limits = await MainActor.run {
                self.modelPickerState.currentModelInfo(current: self.currentModel)?.providerImageLimits ?? .default
            }
            guard let result = await ImageProcessor.process(
                originalData: data,
                mimeType: detectedMime,
                limits: limits
            ) else {
                logger.warning("Failed to process library image", category: .chat)
                continue
            }

            let attachment = Attachment(
                type: .image,
                data: result.data,
                mimeType: result.mimeType,
                fileName: nil,
                originalSize: data.count,
                wasConverted: result.wasConverted,
                originalMimeType: result.wasConverted ? detectedMime : nil
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
