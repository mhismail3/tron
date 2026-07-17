import Foundation
import PhotosUI
import SwiftUI

/// Protocol defining the context required by MessagingCoordinator.
///
/// This protocol allows MessagingCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with message sending and state.
@MainActor
protocol MessagingContext: ChatCoordinatorContext, LocalChatNotificationPresenting {
    var sessionId: String { get }
    var agentPhase: AgentPhase { get set }

    /// The current input text
    var inputText: String { get set }

    /// The current attachments pending to send
    var attachments: [Attachment] { get set }

    /// Selected images from photo picker
    var selectedImages: [PhotosPickerItem] { get set }

    /// Current turn number
    var currentTurn: Int { get set }

    /// Send prompt to the server
    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws

    /// Ensure this view is actively subscribed to the current session's engine
    /// event stream before a prompt starts producing output.
    func ensureLiveEventSubscription() async throws

    /// Ask the server to cancel the active run. A `true` result means a run
    /// matched; terminal lifecycle events still own the final outcome.
    func abortAgentOnServer(idempotencyKey: EngineIdempotencyKey) async throws -> Bool

    func setSessionProcessing(_ isProcessing: Bool)
    func resetStreamingManager()
    func updateSessionActivitySummary(lastUserPrompt: String?, lastAssistantResponse: String?)

    /// Append a message to the chat
    func appendMessage(_ message: ChatMessage)
    /// Remove one optimistic message when the server rejects it before acceptance.
    func removeMessage(id: UUID)
    /// Clear temporary local notifications after a new user action supersedes them.
    func clearLocalNotifications()

    /// Draft store for clearing persisted drafts after send
    var draftStore: DraftStore? { get }
}

/// Coordinates message sending, agent abort, and attachment management for ChatViewModel.
///
/// Responsibilities:
/// - Sending messages with text, attachments, and reasoning levels
/// - Admitting only one prompt submission before server acceptance
/// - Creating appropriate user message UI
/// - Coalescing Stop intent while server lifecycle events own terminal cleanup
/// - Attachment add/remove operations
/// - Coordinating state updates (agentPhase, session list, streaming)
///
/// This coordinator extracts messaging logic from ChatViewModel+Messaging.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class MessagingCoordinator {

    /// Short-lived reservation between a local send/retry action and server
    /// acceptance. Accepted/running lifecycle state remains owned by
    /// `MessagingContext.agentPhase`.
    private var promptSubmissionInFlight = false
    /// Stop tapped after the UI entered processing but before the prompt RPC
    /// acknowledged an active run. The intent is issued once after acceptance.
    private var abortQueuedForPromptAcceptance = false
    /// Short-lived network reservation. The longer-lived `.stopping` phase
    /// suppresses more Stop requests until the server terminalizes the run.
    private var abortRequestInFlight = false

    // MARK: - Initialization

    init() {}

    // MARK: - Send Message

    /// Send a message to the agent.
    ///
    /// - Parameters:
    ///   - reasoningLevel: Optional reasoning level for extended thinking
    ///   - context: The context providing access to state and dependencies
    ///   - onPromptSent: Called with the trimmed text prompt only after the
    ///     server accepts the send request.
    func sendMessage(
        reasoningLevel: String? = nil,
        context: MessagingContext,
        onPromptSent: ((String) -> Void)? = nil
    ) async {
        let submittedInput = context.inputText
        let submittedAttachments = context.attachments
        let text = submittedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !submittedAttachments.isEmpty else {
            context.logVerbose("sendMessage() called but no text or attachments to send")
            return
        }
        guard reservePromptSubmission(context: context) else { return }
        defer { promptSubmissionInFlight = false }

        context.logInfo("Sending message: \"\(text.prefix(100))...\" with \(submittedAttachments.count) attachments, reasoningLevel=\(reasoningLevel ?? "nil")")
        guard await preparePromptSend(context: context, lastUserPrompt: nil) else { return }

        let fileAttachments = submittedAttachments.map { FileAttachment(attachment: $0) }
        let attachmentsToShow = submittedAttachments.isEmpty ? nil : submittedAttachments
        let optimisticMessage: ChatMessage
        let incrementsTurn: Bool

        if !text.isEmpty {
            optimisticMessage = ChatMessage.user(text, attachments: attachmentsToShow)
            incrementsTurn = true
            context.appendMessage(optimisticMessage)
            context.logDebug("Added user text message with \(submittedAttachments.count) attachments")
            context.currentTurn += 1
        } else {
            optimisticMessage = ChatMessage(
                role: .user,
                content: .attachments(submittedAttachments),
                attachments: submittedAttachments
            )
            incrementsTurn = false
            context.appendMessage(optimisticMessage)
            context.logDebug("Added attachment-only message with \(submittedAttachments.count) attachments")
        }

        do {
            context.logDebug("Calling sendPromptToServer with \(fileAttachments.count) attachments...")
            try await context.sendPromptToServer(
                text: text,
                attachments: fileAttachments.isEmpty ? nil : fileAttachments,
                reasoningLevel: reasoningLevel,
                idempotencyKey: .userAction("agent.prompt")
            )
            context.logInfo("Prompt sent successfully")
            context.updateSessionActivitySummary(lastUserPrompt: text, lastAssistantResponse: nil)
            commitSubmittedComposer(
                input: submittedInput,
                attachments: submittedAttachments,
                context: context
            )
            if context.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               context.attachments.isEmpty,
               context.selectedImages.isEmpty {
                await context.draftStore?.clearDraft(sessionId: context.sessionId)
            }
            if !text.isEmpty {
                onPromptSent?(text)
            }
            await issueQueuedAbortIfNeeded(context: context)
        } catch {
            abortQueuedForPromptAcceptance = false
            context.logError("Failed to send prompt: \(error.localizedDescription)")
            context.removeMessage(id: optimisticMessage.id)
            if incrementsTurn {
                context.currentTurn = max(0, context.currentTurn - 1)
            }
            handlePreAcceptPromptFailure(
                context: context,
                dedupKey: "agent.prompt.send.failed",
                title: "Could not send message",
                message: error.localizedDescription,
                suggestion: "Check the connection, then send the message again."
            )
        }
    }

    /// Commit only the composer values represented by the accepted prompt.
    /// Any edits made after the user initiated submission remain as the next
    /// unsent draft.
    private func commitSubmittedComposer(
        input submittedInput: String,
        attachments submittedAttachments: [Attachment],
        context: MessagingContext
    ) {
        if context.inputText.hasPrefix(submittedInput) {
            context.inputText = String(context.inputText.dropFirst(submittedInput.count))
        }

        let submittedAttachmentIds = Set(submittedAttachments.map(\.id))
        context.attachments.removeAll { submittedAttachmentIds.contains($0.id) }
    }

    /// Retry a prompt already present in history without consuming composer
    /// state or appending a duplicate local user bubble.
    func retryMessage(
        prompt: String,
        attachments: [FileAttachment]?,
        context: MessagingContext
    ) async {
        context.logInfo("Retrying last turn (\"\(prompt.prefix(50))...\")")

        guard reservePromptSubmission(context: context) else { return }
        defer { promptSubmissionInFlight = false }
        guard await preparePromptSend(context: context, lastUserPrompt: prompt) else { return }

        do {
            try await context.sendPromptToServer(
                text: prompt,
                attachments: attachments,
                reasoningLevel: nil,
                idempotencyKey: .userAction("agent.prompt.retry")
            )
            await issueQueuedAbortIfNeeded(context: context)
        } catch {
            abortQueuedForPromptAcceptance = false
            context.logError("Retry failed: \(error.localizedDescription)")
            handlePreAcceptPromptFailure(
                context: context,
                dedupKey: "turn.retry.failed",
                title: "Could not retry",
                message: error.localizedDescription,
                suggestion: "Check the connection, then retry the turn again."
            )
        }
    }

    private func reservePromptSubmission(context: MessagingContext) -> Bool {
        guard !promptSubmissionInFlight, !context.agentPhase.isActive else {
            context.logDebug("Ignoring prompt submission while another turn is being admitted or processed")
            return false
        }
        promptSubmissionInFlight = true
        abortQueuedForPromptAcceptance = false
        return true
    }

    private func preparePromptSend(
        context: MessagingContext,
        lastUserPrompt: String?
    ) async -> Bool {
        context.clearLocalNotifications()
        do {
            try await context.ensureLiveEventSubscription()
        } catch {
            context.logError("Failed to subscribe to live session events: \(error.localizedDescription)")
            context.showError("Could not start live session stream: \(error.localizedDescription)")
            return false
        }

        context.agentPhase = .processing
        context.setSessionProcessing(true)
        if let lastUserPrompt {
            context.updateSessionActivitySummary(lastUserPrompt: lastUserPrompt, lastAssistantResponse: nil)
        }
        context.resetStreamingManager()
        return true
    }

    private func handlePreAcceptPromptFailure(
        context: MessagingContext,
        dedupKey: String,
        title: String,
        message: String,
        suggestion: String?
    ) {
        context.agentPhase = .idle
        context.setSessionProcessing(false)
        context.appendLocalError(
            dedupKey: dedupKey,
            title: title,
            message: message,
            suggestion: suggestion
        )
    }

    // MARK: - Abort Agent

    /// Request cancellation of the currently running agent.
    ///
    /// A successful RPC only proves that the server matched an active run. The
    /// canonical `agent.turn_failed` / `agent.complete` sequence owns interruption
    /// presentation, streaming finalization, and the transition back to idle.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func abortAgent(context: MessagingContext) async {
        guard context.agentPhase.isActive else {
            context.logDebug("Ignoring Stop because no agent run is active")
            return
        }
        guard context.agentPhase != .stopping, !abortRequestInFlight else {
            context.logDebug("Ignoring duplicate Stop while cancellation is pending")
            return
        }

        if promptSubmissionInFlight {
            abortQueuedForPromptAcceptance = true
            context.logInfo("Queued Stop until prompt admission completes")
            return
        }

        await requestAbort(context: context)
    }

    private func issueQueuedAbortIfNeeded(context: MessagingContext) async {
        guard abortQueuedForPromptAcceptance else { return }
        abortQueuedForPromptAcceptance = false
        await requestAbort(context: context)
    }

    private func requestAbort(context: MessagingContext) async {
        guard context.agentPhase.isActive,
              context.agentPhase != .stopping,
              !abortRequestInFlight else { return }

        abortRequestInFlight = true
        context.agentPhase = .stopping
        defer {
            abortRequestInFlight = false
            if Task.isCancelled {
                // Cancellation of the local waiter is not proof that the
                // server accepted Stop. Keep the turn active until reconnect
                // or canonical terminal events establish the outcome.
                restoreProcessingAfterUnmatchedAbort(context: context)
            }
        }
        context.logInfo("Requesting agent cancellation...")

        do {
            let matched = try await context.abortAgentOnServer(
                idempotencyKey: .userAction("agent.abort")
            )
            guard !Task.isCancelled else { return }
            if matched {
                context.logInfo("Agent cancellation matched an active run; awaiting terminal events")
            } else {
                restoreProcessingAfterUnmatchedAbort(context: context)
                context.logInfo("Agent cancellation matched no active run")
            }
        } catch {
            guard !Task.isCancelled else { return }
            restoreProcessingAfterUnmatchedAbort(context: context)
            context.logError("Failed to abort agent: \(error.localizedDescription)")
            context.showError(error.localizedDescription)
        }
    }

    private func restoreProcessingAfterUnmatchedAbort(context: MessagingContext) {
        guard context.agentPhase == .stopping else { return }
        context.agentPhase = .processing
    }

    // MARK: - Attachment Management

    /// Add an attachment to the pending attachments.
    ///
    /// - Parameters:
    ///   - attachment: The attachment to add
    ///   - context: The context providing access to state
    func addAttachment(_ attachment: Attachment, context: MessagingContext) {
        context.attachments.append(attachment)
    }

    /// Remove an attachment from the pending attachments.
    ///
    /// - Parameters:
    ///   - attachment: The attachment to remove
    ///   - context: The context providing access to state
    func removeAttachment(_ attachment: Attachment, context: MessagingContext) {
        context.attachments.removeAll { $0.id == attachment.id }
    }

}
