import SwiftUI
import PhotosUI

// MARK: - Message Sending & Image Handling

extension ChatViewModel {

    func sendMessage(reasoningLevel: String? = nil, skills: [Skill]? = nil, spells: [Skill]? = nil) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else {
            logger.verbose("sendMessage() called but no text or attachments to send", category: .chat)
            return
        }

        logger.info("Sending message: \"\(text.prefix(100))...\" with \(attachments.count) attachments, \(skills?.count ?? 0) skills, \(spells?.count ?? 0) spells, reasoningLevel=\(reasoningLevel ?? "nil")", category: .chat)

        // Check if this is an AskUserQuestion answer prompt - don't mark as superseded
        let isAnswerPrompt = text.hasPrefix("[Answers to your questions]")

        if !isAnswerPrompt {
            // Mark any pending AskUserQuestion chips as superseded
            // (user chose to send a different message instead of answering)
            markPendingQuestionsAsSuperseded()
        }

        // Reset browser dismiss flag for new prompt - browser can auto-open again
        browserState.userDismissedBrowserThisTurn = false

        // Create user message with attachments, skills, and spells displayed above text
        let attachmentsToShow = attachments.isEmpty ? nil : attachments
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
                appendMessage(answerChip)
                logger.debug("Added answered questions chip", category: .chat)
            } else {
                let userMessage = ChatMessage.user(text, attachments: attachmentsToShow, skills: skillsToShow, spells: spellsToShow)
                appendMessage(userMessage)
                logger.debug("Added user text message with \(attachments.count) attachments, \(skills?.count ?? 0) skills, and \(spells?.count ?? 0) spells", category: .chat)
            }
            currentTurn += 1
        } else if !attachments.isEmpty {
            // If only attachments (no text), still show them in chat
            let attachmentMessage = ChatMessage(role: .user, content: .attachments(attachments), attachments: attachments, skills: skillsToShow, spells: spellsToShow)
            appendMessage(attachmentMessage)
            logger.debug("Added attachment-only message with \(attachments.count) attachments", category: .chat)
        }

        inputText = ""
        isProcessing = true

        // Update dashboard processing state
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: true)
        eventStoreManager?.updateSessionDashboardInfo(sessionId: sessionId, lastUserPrompt: text)

        // Reset streaming state before new message
        // Note: Streaming message is created by StreamingManager on first text delta
        streamingManager.reset()  // Clears streamingMessageId and streamingText

        // Prepare file attachments for sending
        let fileAttachments = attachments.map { FileAttachment(attachment: $0) }
        attachments = []
        selectedImages = []

        // Send to server
        Task {
            do {
                logger.debug("Calling rpcClient.sendPrompt() with \(fileAttachments.count) attachments, \(skills?.count ?? 0) skills, \(spells?.count ?? 0) spells...", category: .chat)
                try await rpcClient.agent.sendPrompt(
                    text,
                    images: nil,  // Legacy - no longer used
                    attachments: fileAttachments.isEmpty ? nil : fileAttachments,
                    reasoningLevel: reasoningLevel,
                    skills: skills,
                    spells: spells
                )
                logger.info("Prompt sent successfully", category: .chat)
            } catch {
                logger.error("Failed to send prompt: \(error.localizedDescription)", category: .chat)
                handleAgentError("Failed to send message: \(error.localizedDescription)")
            }
        }
    }

    func abortAgent() {
        logger.info("Aborting agent...", category: .chat)
        Task {
            do {
                try await rpcClient.agent.abort()
                isProcessing = false
                eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
                eventStoreManager?.updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: "Interrupted"
                )
                finalizeStreamingMessage()
                messages.append(.interrupted())
                logger.info("Agent aborted successfully", category: .chat)

                // Close browser session when agent is interrupted
                closeBrowserSession()
            } catch {
                logger.error("Failed to abort agent: \(error.localizedDescription)", category: .chat)
                showErrorAlert(error.localizedDescription)
            }
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
        attachments.append(attachment)
    }

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }
}
