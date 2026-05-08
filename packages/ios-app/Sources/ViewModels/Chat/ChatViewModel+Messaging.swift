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

    func activateSkillOnServer(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try await engineClient.agent.activateSkill(skillName, idempotencyKey: idempotencyKey)
    }

    func deactivateSkillOnServer(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try await engineClient.agent.deactivateSkill(skillName, idempotencyKey: idempotencyKey)
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

    /// Dismiss any pending or queued subagent results.
    /// Called when user sends a different message (not via the "Send" button).
    func dismissPendingSubagentResults() {
        let pendingIds = subagentState.allSubagentsSorted
            .filter { $0.resultDeliveryStatus == .pending }
            .map { $0.subagentSessionId }

        for sessionId in pendingIds {
            subagentState.markResultsDismissed(subagentSessionId: sessionId)
        }

        if !pendingIds.isEmpty {
            let pendingSet = Set(pendingIds)
            removeFromMessages { msg in
                if case .systemEvent(.subagentResultAvailable(let sid, _, _)) = msg.content {
                    return pendingSet.contains(sid)
                }
                return false
            }
            logger.info("Dismissed \(pendingIds.count) pending subagent result(s) - user sent different message", category: .chat)
        }
    }
}

// MARK: - Message Sending & Image Handling

extension ChatViewModel {

    /// Execute pending source changes prompt (deferred from sheet dismiss).
    /// Called from ChatSheetModifier.onDismiss AFTER sheet dismiss animation completes.
    func executePendingSourceChangesSubmission() {
        guard let prompt = pendingSourceChangesPrompt else { return }
        pendingSourceChangesPrompt = nil
        inputText = prompt
        sendMessage()
    }

    /// Send a message to the agent
    func sendMessage(reasoningLevel: String? = nil, skills: [Skill]? = nil) {
        Task {
            await messagingCoordinator.sendMessage(
                reasoningLevel: reasoningLevel,
                skills: skills,
                context: self
            )
        }
    }

    /// Activate staged skills server-side, then send the prompt.
    ///
    /// Fire-and-forget wrapper for use by SwiftUI button handlers. If
    /// activation fails, the coordinator surfaces an error via `showError`
    /// and does NOT send — see `MessagingCoordinator.activateAndSend`.
    func activateSkillsAndSend(reasoningLevel: String? = nil, skills: [Skill]) {
        Task {
            await messagingCoordinator.activateAndSend(
                reasoningLevel: reasoningLevel,
                skills: skills,
                context: self
            )
        }
    }

    /// Activate a single skill server-side with user-visible error handling.
    ///
    /// Used by chip re-activation (e.g. the skills-cleared "re-activate?" picker).
    /// Unlike `activateSkillsAndSend`, this is not tied to a send — it's a
    /// one-shot user gesture. On failure, surfaces an error via `showError`.
    func reactivateSkillWithUserErrorHandling(_ skillName: String) {
        Task {
            do {
                try await activateSkillOnServer(skillName, idempotencyKey: .userAction("skills.activate"))
            } catch {
                logError("Failed to re-activate skill '\(skillName)': \(error.localizedDescription)")
                showError("Could not re-activate skill: \(error.localizedDescription)")
            }
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

    /// Cooperatively abort a single in-flight tool call without stopping the turn.
    /// The server cancels the per-tool CancellationToken so the tool can observe
    /// cancellation and return an error result; the agent loop continues.
    func abortTool(toolCallId: String, idempotencyKey: EngineIdempotencyKey) {
        Task {
            do {
                _ = try await engineClient.agent.abortTool(toolCallId: toolCallId, idempotencyKey: idempotencyKey)
            } catch {
                logError("Failed to abort tool \(toolCallId): \(error.localizedDescription)")
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
    /// the traversal order, skip semantics, and "no text prompt" fallback
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

    // MARK: - Draft Skill Management

    /// Stage a skill chip on the input bar. Local-only; server activation is
    /// deferred to the send path.
    func addSkillToDraft(_ skill: Skill) {
        messagingCoordinator.addSkillToDraft(skill, context: self)
    }

    /// Unstage a skill chip from the input bar. Local-only; does not
    /// deactivate the skill on the server.
    func removeSkillFromDraft(_ skill: Skill) {
        messagingCoordinator.removeSkillFromDraft(skill, context: self)
    }
}
