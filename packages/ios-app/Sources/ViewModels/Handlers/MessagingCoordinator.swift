import Foundation
import PhotosUI
import SwiftUI

/// Protocol defining the context required by MessagingCoordinator.
///
/// This protocol allows MessagingCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with message sending and state.
@MainActor
protocol MessagingContext: LoggingContext {
    /// The current input text
    var inputText: String { get set }

    /// The current attachments pending to send
    var attachments: [Attachment] { get set }

    /// Selected images from photo picker
    var selectedImages: [PhotosPickerItem] { get set }

    /// Whether the agent is currently processing
    var isProcessing: Bool { get set }

    /// Current turn number
    var currentTurn: Int { get set }

    /// Current session ID
    var sessionId: String { get }

    /// Whether the user dismissed the browser this turn
    var userDismissedBrowserThisTurn: Bool { get set }

    /// Send prompt to the server
    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?,
        spells: [Skill]?
    ) async throws

    /// Abort the agent on the server
    func abortAgentOnServer() async throws

    /// Append a message to the chat
    func appendMessage(_ message: ChatMessage)

    /// Append the interrupted message
    func appendInterruptedMessage()

    /// Mark pending AskUserQuestion chips as superseded
    func markPendingQuestionsAsSuperseded()

    /// Reset the streaming manager state
    func resetStreamingManager()

    /// Finalize any streaming message
    func finalizeStreamingMessage()

    /// Close the browser session
    func closeBrowserSession()

    /// Set session processing state in dashboard
    func setSessionProcessing(_ isProcessing: Bool)

    /// Update session dashboard info
    func updateSessionDashboardInfo(lastUserPrompt: String?, lastAssistantResponse: String?)

    /// Handle agent error
    func handleAgentError(_ message: String)

    /// Show error alert to user
    func showErrorAlert(_ message: String)
}

/// Coordinates message sending, agent abort, and attachment management for ChatViewModel.
///
/// Responsibilities:
/// - Sending messages with text, attachments, skills, and reasoning levels
/// - Creating appropriate user message UI (regular text or answered questions chip)
/// - Managing agent abort with proper state cleanup
/// - Attachment add/remove operations
/// - Coordinating state updates (isProcessing, dashboard, streaming)
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
    /// - Parameters:
    ///   - reasoningLevel: Optional reasoning level for extended thinking
    ///   - skills: Optional skills to enable for this message
    ///   - spells: Optional spells to apply
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

        context.logInfo("Sending message: \"\(text.prefix(100))...\" with \(context.attachments.count) attachments, \(skills?.count ?? 0) skills, \(spells?.count ?? 0) spells, reasoningLevel=\(reasoningLevel ?? "nil")")

        // Check if this is an AskUserQuestion answer prompt - don't mark as superseded
        let isAnswerPrompt = text.hasPrefix("[Answers to your questions]")

        if !isAnswerPrompt {
            // Mark any pending AskUserQuestion chips as superseded
            // (user chose to send a different message instead of answering)
            context.markPendingQuestionsAsSuperseded()
        }

        // Reset browser dismiss flag for new prompt - browser can auto-open again
        context.userDismissedBrowserThisTurn = false

        // Create user message with attachments, skills, and spells displayed above text
        let attachmentsToShow = context.attachments.isEmpty ? nil : context.attachments
        let skillsToShow = skills?.isEmpty == false ? skills : nil
        let spellsToShow = spells?.isEmpty == false ? spells : nil

        if !text.isEmpty {
            if isAnswerPrompt {
                // Show "Answered agent's questions" chip instead of full text
                let questionCount = text.components(separatedBy: "\n**").count - 1
                let answerChip = ChatMessage(
                    role: .user,
                    content: .answeredQuestions(questionCount: max(1, questionCount))
                )
                context.appendMessage(answerChip)
                context.logDebug("Added answered questions chip")
            } else {
                let userMessage = ChatMessage.user(text, attachments: attachmentsToShow, skills: skillsToShow, spells: spellsToShow)
                context.appendMessage(userMessage)
                context.logDebug("Added user text message with \(context.attachments.count) attachments, \(skills?.count ?? 0) skills, and \(spells?.count ?? 0) spells")
            }
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

        // Send to server
        do {
            context.logDebug("Calling sendPromptToServer with \(fileAttachments.count) attachments, \(skills?.count ?? 0) skills, \(spells?.count ?? 0) spells...")
            try await context.sendPromptToServer(
                text: text,
                attachments: fileAttachments.isEmpty ? nil : fileAttachments,
                reasoningLevel: reasoningLevel,
                skills: skills,
                spells: spells
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
            context.setSessionProcessing(false)
            context.updateSessionDashboardInfo(lastUserPrompt: nil, lastAssistantResponse: "Interrupted")
            context.finalizeStreamingMessage()
            context.appendInterruptedMessage()
            context.logInfo("Agent aborted successfully")

            // Close browser session when agent is interrupted
            context.closeBrowserSession()
        } catch {
            context.logError("Failed to abort agent: \(error.localizedDescription)")
            context.showErrorAlert(error.localizedDescription)
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
