import SwiftUI
import PhotosUI

/// Narrow adapter for the external PhotosPicker transfer boundary.
///
/// The value keeps PhotosUI transfer lifetime outside `ChatViewModel`; the live
/// implementation delegates directly to Apple's transferable loader.
struct PhotoPickerDataLoader: Sendable {
    let load: @Sendable (PhotosPickerItem) async -> Data?

    static let live = Self { item in
        try? await item.loadTransferable(type: Data.self)
    }
}

// MARK: - MessagingContext Conformance

extension ChatViewModel: MessagingContext {

    func removeMessage(id: UUID) {
        removeFromMessages { $0.id == id }
    }

    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        try await services.agent.sendPrompt(
            text,
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            idempotencyKey: idempotencyKey
        )
    }

    func ensureLiveEventSubscription() async throws {
        logger.info("Ensuring live engine event subscription before continuity-sensitive work", category: .events)
        try await services.events.ensureSessionEventSubscription(sessionId: sessionId, workspaceId: nil)
    }

    func abortAgentOnServer(idempotencyKey: EngineIdempotencyKey) async throws -> Bool {
        try await services.agent.abort(idempotencyKey: idempotencyKey)
    }

    // Note: The following methods are already defined in other extensions:
    // - resetStreamingManager() in ChatViewModel+TurnLifecycleContext.swift
    // - setSessionProcessing(_:) in ChatViewModel+TurnLifecycleContext.swift
    // - handleAgentError(_:) in ChatViewModel+Events.swift
    // - logDebug/Info/Warning/Error in ChatViewModel.swift
    // MessagingContext conformance uses those existing implementations.

    func updateSessionActivitySummary(lastUserPrompt: String?, lastAssistantResponse: String?) {
        if let prompt = lastUserPrompt {
            eventStoreManager?.updateSessionActivitySummary(sessionId: sessionId, lastUserPrompt: prompt)
        }
        if let response = lastAssistantResponse {
            eventStoreManager?.updateSessionActivitySummary(sessionId: sessionId, lastAssistantResponse: response)
        }
    }

}

// MARK: - Message Sending & Image Handling

extension ChatViewModel {

    func currentUserInputRequest(invocationId: String) -> UserInputRequest? {
        for message in messages.reversed() {
            guard case .userInputRequest(let request) = message.content,
                  request.invocationId == invocationId else { continue }
            return request
        }
        return nil
    }

    func submitUserInput(
        invocationId: String,
        answers: [UserInputAnswer]
    ) async throws {
        try await services.events.ensureSessionEventSubscription(
            sessionId: sessionId,
            workspaceId: nil
        )
        try await services.agent.answerUserInput(
            invocationId: invocationId,
            answers: answers,
            idempotencyKey: .userAction("agent.answerUserInput.\(invocationId)")
        )
        if let index = messages.lastIndex(where: {
            if case .userInputRequest(let request) = $0.content {
                return request.invocationId == invocationId
            }
            return false
        }), case .userInputRequest(var request) = messages[index].content {
            request.answers = answers
            request.status = .answered
            updateMessage(at: index) { message in
                message.content = .userInputRequest(request)
            }
        }
        appendToMessages(ChatMessage(
            role: .user,
            content: .userInputAnswer(UserInputAnswerPresentation(
                invocationId: invocationId,
                answers: answers
            ))
        ))
        pendingUserInputRequest = nil
    }

    /// Send a message to the agent.
    func sendMessage(reasoningLevel: String? = nil, onPromptSent: ((String) -> Void)? = nil) {
        Task {
            await messagingCoordinator.sendMessage(
                reasoningLevel: reasoningLevel,
                context: self,
                onPromptSent: onPromptSent
            )
        }
    }

    /// Abort the currently running agent.
    ///
    /// Stop is a session mutation, not mounted-view work. Its short-lived
    /// request therefore survives transient view disappearance; canonical
    /// terminal events or reconstruction still own the final phase.
    func abortAgent() {
        Task {
            await messagingCoordinator.abortAgent(context: self)
        }
    }

    /// Cooperatively abort a single in-flight tool invocation without stopping the turn.
    /// The server cancels the per-invocation CancellationToken so the tool can observe
    /// cancellation and return an error result; the agent loop continues.
    func abortToolInvocation(invocationId: String, idempotencyKey: EngineIdempotencyKey) {
        Task {
            do {
                _ = try await services.agent.abortToolInvocation(invocationId: invocationId, idempotencyKey: idempotencyKey)
            } catch {
                logError("Failed to abort tool \(invocationId): \(error.localizedDescription)")
                appendLocalError(dedupKey: "tool.abort.\(invocationId)", title: "Could not cancel action", message: error.localizedDescription)
            }
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
    /// - If found, sends the prompt through the agent repository with that text and
    ///   the message's original attachments; the server emits a fresh
    ///   `message.user` event and starts a new turn.
    /// - If not found (empty history, or last user message is an image-only
    ///   attachment with no text), surfaces a user-visible error rather
    ///   than silently no-op'ing. Image-only retry would require
    ///   re-uploading binary content we no longer hold, so we ask the user
    ///   to re-compose.
    ///
    /// Limitation: the retry targets the LATEST user prompt, not the prompt
    /// that failed. If another text prompt is added after the failed one,
    /// this retries the newer prompt. In practice the send button is disabled
    /// during a failed turn until the retry lands, so this is rarely
    /// ambiguous, but future callers should preserve the newest-first rule.
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

        let fileAttachments: [FileAttachment]? = lastUserMessage.attachments?.map { attachment in
            FileAttachment(attachment: attachment)
        }

        Task {
            await messagingCoordinator.retryMessage(
                prompt: prompt,
                attachments: fileAttachments,
                context: self
            )
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

    // MARK: - Image Handling

    func startSelectedImageProcessing(_ items: [PhotosPickerItem]) {
        selectedImageTask?.cancel()
        selectedImageTask = nil
        guard !items.isEmpty else { return }

        let dataLoader = photoPickerDataLoader
        let events = services.events
        let modelPickerState = modelPickerState
        let inputBarState = inputBarState

        selectedImageTask = Task { @MainActor [weak self] in
            for item in items {
                guard !Task.isCancelled,
                      inputBarState.selectedImages == items else { return }
                guard let data = await dataLoader.load(item) else {
                    continue
                }
                guard !Task.isCancelled,
                      inputBarState.selectedImages == items else { return }
                guard UIImage(data: data) != nil else {
                    continue
                }

                let limits = modelPickerState.currentModelInfo(
                    current: events.currentModel
                )?.providerImageLimits ?? .default
                guard let attachment = await AttachmentImagePreparer.prepare(
                    data: data,
                    limits: limits
                ) else {
                    guard !Task.isCancelled,
                          inputBarState.selectedImages == items else { return }
                    logger.warning("Failed to process library image", category: .chat)
                    self?.appendLocalError(
                        dedupKey: "attachment.photo.failed",
                        title: "Could not attach photo",
                        message: "The selected photo could not be processed."
                    )
                    continue
                }

                guard !Task.isCancelled,
                      inputBarState.selectedImages == items else { return }
                self?.attachments.append(attachment)
            }

            guard !Task.isCancelled,
                  inputBarState.selectedImages == items,
                  self != nil else { return }
            inputBarState.selectedImages = []
            self?.selectedImageTask = nil
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
