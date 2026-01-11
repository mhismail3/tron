import SwiftUI
import PhotosUI

// MARK: - Message Sending & Image Handling

extension ChatViewModel {

    func sendMessage(reasoningLevel: String? = nil) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty || !attachments.isEmpty else {
            logger.verbose("sendMessage() called but no text, images, or attachments to send", category: .chat)
            return
        }

        logger.info("Sending message: \"\(text.prefix(100))...\" with \(attachedImages.count) images, \(attachments.count) attachments, reasoningLevel=\(reasoningLevel ?? "nil")", category: .chat)

        // Create user message
        if !attachedImages.isEmpty {
            let imageMessage = ChatMessage(role: .user, content: .images(attachedImages))
            appendMessage(imageMessage)
            logger.debug("Added image message with \(attachedImages.count) images", category: .chat)
        }

        if !text.isEmpty {
            let userMessage = ChatMessage.user(text)
            appendMessage(userMessage)
            logger.debug("Added user text message", category: .chat)
            currentTurn += 1
        }

        inputText = ""
        isProcessing = true
        thinkingText = ""

        // Update dashboard processing state
        eventStoreManager?.setSessionProcessing(sessionId, isProcessing: true)
        eventStoreManager?.updateSessionDashboardInfo(sessionId: sessionId, lastUserPrompt: text)

        // Create streaming placeholder
        let streamingMessage = ChatMessage.streaming()
        messages.append(streamingMessage)
        streamingMessageId = streamingMessage.id
        streamingText = ""
        logger.verbose("Created streaming placeholder message id=\(streamingMessage.id)", category: .chat)

        // Prepare legacy image attachments
        let imageAttachments = attachedImages.map {
            ImageAttachment(data: $0.data, mimeType: $0.mimeType)
        }
        attachedImages = []
        selectedImages = []

        // Prepare unified file attachments
        let fileAttachments = attachments.map { FileAttachment(attachment: $0) }
        attachments = []

        // Send to server
        Task {
            do {
                logger.debug("Calling rpcClient.sendPrompt() with \(imageAttachments.count) images and \(fileAttachments.count) attachments...", category: .chat)
                try await rpcClient.sendPrompt(
                    text,
                    images: imageAttachments.isEmpty ? nil : imageAttachments,
                    attachments: fileAttachments.isEmpty ? nil : fileAttachments,
                    reasoningLevel: reasoningLevel
                )
                logger.info("Prompt sent successfully", category: .chat)
            } catch {
                logger.error("Failed to send prompt: \(error.localizedDescription)", category: .chat)
                handleError(error.localizedDescription)
            }
        }
    }

    func abortAgent() {
        logger.info("Aborting agent...", category: .chat)
        Task {
            do {
                try await rpcClient.abortAgent()
                isProcessing = false
                eventStoreManager?.setSessionProcessing(sessionId, isProcessing: false)
                eventStoreManager?.updateSessionDashboardInfo(
                    sessionId: sessionId,
                    lastAssistantResponse: "Interrupted"
                )
                finalizeStreamingMessage()
                messages.append(.interrupted())
                logger.info("Agent aborted successfully", category: .chat)
            } catch {
                logger.error("Failed to abort agent: \(error.localizedDescription)", category: .chat)
                showErrorAlert(error.localizedDescription)
            }
        }
    }

    // MARK: - Image Handling

    func processSelectedImages(_ items: [PhotosPickerItem]) async {
        var newImages: [ImageContent] = []

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let mimeType = "image/jpeg"
                newImages.append(ImageContent(data: data, mimeType: mimeType))
            }
        }

        await MainActor.run {
            self.attachedImages.append(contentsOf: newImages)
        }
    }

    func removeAttachedImage(_ image: ImageContent) {
        attachedImages.removeAll { $0.id == image.id }
    }

    // MARK: - Unified Attachment Handling

    func addAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
    }

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }
}
