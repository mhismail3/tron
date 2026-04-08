import Foundation
import PhotosUI
import SwiftUI

/// Protocol defining the context required by MessagingCoordinator.
///
/// This protocol allows MessagingCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with message sending and state.
///
/// Inherits from:
/// - LoggingContext: Logging and error display (showError)
/// - SessionIdentifiable: Session ID access
/// - ProcessingTrackable: Processing state and dashboard updates
/// - StreamingManaging: Streaming state management
/// - DashboardUpdating: Dashboard info updates
@MainActor
protocol MessagingContext: LoggingContext, SessionIdentifiable, ProcessingTrackable, StreamingManaging, DashboardUpdating {
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
        reasoningLevel: String?
    ) async throws

    /// Activate a skill in the current session (server-owned state)
    func activateSkillOnServer(_ skillName: String) async throws

    /// Deactivate a skill from the current session
    func deactivateSkillOnServer(_ skillName: String) async throws

    /// Cast an ephemeral spell for the next prompt only
    func castSpellOnServer(_ spellName: String) async throws

    /// Abort the agent on the server
    func abortAgentOnServer() async throws

    /// Append a message to the chat
    func appendMessage(_ message: ChatMessage)

    /// Append the interrupted message
    func appendInterruptedMessage()

    /// Mark pending AskUserQuestion chips as superseded
    func markPendingQuestionsAsSuperseded()

    /// Mark pending GetConfirmation chips as superseded
    func markPendingConfirmationsAsSuperseded()

    /// Dismiss pending subagent results (user chose to send a different message)
    func dismissPendingSubagentResults()

    /// Handle agent error
    func handleAgentError(_ message: String)

    /// Finalize thinking message (mark as no longer streaming)
    /// Called on abort to stop the pulsing thinking icon
    func finalizeThinkingMessage()

    /// Clear the thinking caption state
    /// Called on abort to remove the thinking caption
    func clearThinkingCaption()

    /// Mark that we're expecting suggestions from the hook (called on abort).
    func markAwaitingSuggestions()

    /// Draft store for clearing persisted drafts after send
    var draftStore: DraftStore? { get }
}

/// Coordinates message sending, agent abort, and attachment management for ChatViewModel.
///
/// Responsibilities:
/// - Sending messages with text, attachments, skills, and reasoning levels
/// - Creating appropriate user message UI (regular text or answered questions chip)
/// - Managing agent abort with proper state cleanup
/// - Attachment add/remove operations
/// - Coordinating state updates (agentPhase, dashboard, streaming)
///
/// This coordinator extracts messaging logic from ChatViewModel+Messaging.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class MessagingCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Send Message

    /// Send a message to the agent.
    ///
    /// Skills and spells are managed via separate RPCs (skill.activate, spell.cast),
    /// not sent with the prompt. The server reads active skills from session state.
    ///
    /// - Parameters:
    ///   - reasoningLevel: Optional reasoning level for extended thinking
    ///   - skills: Skills to display as chips on the user message (already activated server-side)
    ///   - spells: Spells to display as chips on the user message (already cast server-side)
    ///   - context: The context providing access to state and dependencies
    func sendMessage(
        reasoningLevel: String? = nil,
        skills: [Skill]? = nil,
        spells: [Skill]? = nil,
        context: MessagingContext
    ) async {
        let text = context.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !context.attachments.isEmpty else {
            context.logVerbose("sendMessage() called but no text or attachments to send")
            return
        }

        context.logInfo("Sending message: \"\(text.prefix(100))...\" with \(context.attachments.count) attachments, reasoningLevel=\(reasoningLevel ?? "nil")")

        // Confirmation/answer submissions and subagent results are delivered via
        // dedicated RPCs, not through sendMessage. Any regular user message sent here
        // supersedes pending interactive tools and dismisses subagent notifications.
        context.markPendingQuestionsAsSuperseded()
        context.markPendingConfirmationsAsSuperseded()
        context.dismissPendingSubagentResults()

        // Reset browser dismissal for new prompt - browser can auto-open again

        // Create user message with attachments, skills, and spells displayed above text
        let attachmentsToShow = context.attachments.isEmpty ? nil : context.attachments
        let skillsToShow = skills?.isEmpty == false ? skills : nil
        let spellsToShow = spells?.isEmpty == false ? spells : nil

        if !text.isEmpty {
            let userMessage = ChatMessage.user(text, attachments: attachmentsToShow, skills: skillsToShow, spells: spellsToShow)
            context.appendMessage(userMessage)
            context.logDebug("Added user text message with \(context.attachments.count) attachments")
            context.currentTurn += 1
        } else if !context.attachments.isEmpty {
            // If only attachments (no text), still show them in chat
            let attachmentMessage = ChatMessage(role: .user, content: .attachments(context.attachments), attachments: context.attachments, skills: skillsToShow, spells: spellsToShow)
            context.appendMessage(attachmentMessage)
            context.logDebug("Added attachment-only message with \(context.attachments.count) attachments")
        }

        context.inputText = ""
        context.isProcessing = true

        // Update dashboard processing state
        context.setSessionProcessing(true)
        context.updateSessionDashboardInfo(lastUserPrompt: text, lastAssistantResponse: nil)

        // Reset streaming state before new message
        context.resetStreamingManager()

        // Prepare file attachments for sending
        let fileAttachments = context.attachments.map { FileAttachment(attachment: $0) }
        context.attachments = []
        context.selectedImages = []

        // Clear persisted draft now that input state is consumed
        context.draftStore?.clearDraft(sessionId: context.sessionId)

        // Send to server
        do {
            context.logDebug("Calling sendPromptToServer with \(fileAttachments.count) attachments...")
            try await context.sendPromptToServer(
                text: text,
                attachments: fileAttachments.isEmpty ? nil : fileAttachments,
                reasoningLevel: reasoningLevel
            )
            context.logInfo("Prompt sent successfully")
        } catch {
            context.logError("Failed to send prompt: \(error.localizedDescription)")
            context.handleAgentError("Failed to send message: \(error.localizedDescription)")
        }
    }

    // MARK: - Abort Agent

    /// Abort the currently running agent.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func abortAgent(context: MessagingContext) async {
        context.logInfo("Aborting agent...")

        do {
            try await context.abortAgentOnServer()
            context.isProcessing = false
            context.isPostProcessing = false
            context.setSessionProcessing(false)
            context.updateSessionDashboardInfo(lastUserPrompt: nil, lastAssistantResponse: "Interrupted")
            context.finalizeStreamingMessage()
            context.finalizeThinkingMessage()
            context.clearThinkingCaption()
            context.appendInterruptedMessage()
            context.markAwaitingSuggestions()
            context.logInfo("Agent aborted successfully")
        } catch {
            context.logError("Failed to abort agent: \(error.localizedDescription)")
            context.showError(error.localizedDescription)
        }
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
