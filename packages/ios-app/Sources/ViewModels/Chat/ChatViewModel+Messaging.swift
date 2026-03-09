import SwiftUI
import PhotosUI

// MARK: - MessagingContext Conformance

extension ChatViewModel: MessagingContext {
    // browserDismissal is provided by ChatViewModel+TurnLifecycleContext.swift

    var lastAnsweredQuestionCount: Int {
        askUserQuestionState.lastAnsweredQuestionCount
    }

    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?,
        spells: [Skill]?
    ) async throws {
        // Collect device context if enabled in settings
        let deviceContext = await collectDeviceContext()

        try await rpcClient.agent.sendPrompt(
            text,
            images: nil,  // Images sent via attachments instead
            attachments: attachments,
            reasoningLevel: reasoningLevel,
            skills: skills,
            spells: spells,
            deviceContext: deviceContext
        )
    }

    /// Collect device context line from DeviceContextService if enabled.
    private func collectDeviceContext() async -> String? {
        guard let settings = try? await rpcClient.settings.get() else { return nil }
        let integrations = settings.integrations
        guard integrations.deviceContext.enabled else { return nil }
        return DeviceContextService.shared.formatContextLine(
            settings: integrations.deviceContext,
            locationSettings: integrations.location
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

    func cancelActiveDeviceRequests() {
        deviceRequestDispatcher?.cancelAll()
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
        }

        if !pendingIds.isEmpty {
            let pendingSet = Set(pendingIds)
            messages.removeAll { msg in
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

    /// Abort the currently running agent.
    /// If the message queue has items, shows a confirmation dialog instead.
    func abortAgent() {
        if messageQueueState.hasMessages {
            showAbortConfirmation = true
        } else {
            Task { await messagingCoordinator.abortAgent(context: self) }
        }
    }

    /// Abort and discard all queued messages.
    func abortAndClearQueue() {
        messageQueueState.clear()
        Task { await messagingCoordinator.abortAgent(context: self) }
    }

    /// Abort but keep queued messages — drain starts after abort completes.
    func abortKeepQueue() {
        Task {
            await messagingCoordinator.abortAgent(context: self)
            drainMessageQueue()
        }
    }

    // MARK: - Message Queue

    /// Enqueue the current input text for sending when the agent becomes ready.
    /// Only enqueues text — attachments and skills are not included in queued messages.
    func enqueueCurrentInput() {
        let text = inputBarState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard messageQueueState.enqueue(text) else { return }
        inputBarState.text = ""
    }

    /// Drain the next queued message and send it.
    /// Called after agent.ready, error recovery, and compaction completion.
    func drainMessageQueue() {
        guard agentPhase.isIdle else { return }
        guard !isCompacting else { return }
        guard let queued = messageQueueState.dequeue() else { return }
        logInfo("Draining queued message: \"\(queued.text.prefix(50))...\"")
        Task {
            await messagingCoordinator.sendQueuedMessage(text: queued.text, context: self)
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
