import SwiftUI
import PhotosUI

// MARK: - MessagingContext Conformance

extension ChatViewModel: MessagingContext {

    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?
    ) async throws {
        try await rpcClient.agent.sendPrompt(
            text,
            images: nil,  // Images sent via attachments instead
            attachments: attachments,
            reasoningLevel: reasoningLevel
        )
    }

    func activateSkillOnServer(_ skillName: String) async throws {
        _ = try await rpcClient.agent.activateSkill(skillName)
    }

    func deactivateSkillOnServer(_ skillName: String) async throws {
        _ = try await rpcClient.agent.deactivateSkill(skillName)
    }

    func abortAgentOnServer() async throws {
        try await rpcClient.agent.abort()
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
                try await activateSkillOnServer(skillName)
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
    func abortTool(toolCallId: String) {
        Task {
            do {
                _ = try await rpcClient.agent.abortTool(toolCallId: toolCallId)
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
                try await rpcClient.agent.clearQueue()
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
                _ = try await rpcClient.agent.queuePrompt(text)
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
