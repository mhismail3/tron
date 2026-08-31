import Foundation
import Testing

@Suite("Attachment file preview presentation guard")
struct AttachmentFilePreviewGuardTests {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("all file chips route through one nonconditional bounded preview sheet")
    func fileChipRouting() throws {
        let attachment = try source("Sources/UI/Chat/ChatAttachmentPresentation.swift")
        let transcript = try source("Sources/UI/Chat/TranscriptRow.swift")
        let outgoing = try source("Sources/UI/Chat/ChatOutgoingSubmissionRow.swift")
        let queue = try source("Sources/UI/Chat/QueuedMessagePresentation.swift")
        let models = try source("Sources/Models/SessionRuntimeModels.swift")
        let preview = try source("Sources/UI/Chat/AttachmentFilePreviewSheet.swift")
        let loader = try source("Sources/State/ChatMediaLoader.swift")
        let composer = try source("Sources/State/ComposerDraftCoordinator.swift")

        let pending = attachment.components(separatedBy: "struct PendingAttachmentChip").dropFirst().first ?? ""
        #expect(pending.contains("if !isImage || decodedPreviewImage != nil"))
        #expect(pending.contains("AttachmentFilePreviewSheet("))
        #expect(pending.contains(".local(id: attachment.id, data: $0)"))

        let sent = transcript.components(separatedBy: "struct TranscriptFileChip").dropFirst().first ?? ""
        #expect(sent.contains("Button {"))
        #expect(sent.contains("AttachmentThumbnailSurface(image: currentThumbnail"))
        #expect(sent.contains("item: $previewRequest"))
        #expect(sent.contains("AttachmentFilePreviewSheet("))
        #expect(sent.contains(".remote(identity: $0, leaseID: request.id)"))

        let outgoingRow = outgoing.components(separatedBy: "struct ChatOutgoingSubmissionRow").dropFirst().first ?? ""
        #expect(outgoingRow.contains("TranscriptFileChip("))
        #expect(outgoingRow.contains("else if let blobID = attachment.transportBlobID"))
        #expect(outgoingRow.contains("blobID: blobID"))
        #expect(!outgoingRow.contains("blobID: \"upload:\\(attachment.id)\""))
        #expect(outgoingRow.contains("QueuedMessageAttachmentPresentation.chips(for: attachments)"))

        let compact = queue.components(separatedBy: "struct QueuedMessageAttachmentChipRow").dropFirst().first ?? ""
        #expect(compact.contains("Button {"))
        #expect(compact.contains("model.chatMediaIdentity(blobID: $0.id)"))
        #expect(compact.contains("AttachmentFilePreviewSheet("))
        #expect(compact.contains(".remote(identity: $0, leaseID: request.id)"))
        #expect(compact.contains("?? .unavailable"))
        #expect(models.contains("var attachments: [PromptAttachment]? = nil"))

        #expect(preview.contains("import PDFKit"))
        #expect(preview.contains("maximumTextBytes = ChatTextPreparationPolicy.maximumSourceBytes"))
        #expect(preview.contains("static let maximumPDFPages = 512"))
        #expect(preview.contains("Task.detached(priority: .userInitiated)"))
        #expect(preview.contains("TronMarkdownView(document: document, streaming: false)"))
        #expect(preview.contains("TronReadOnlyTextView(text: text, style: .code)"))
        #expect(preview.contains("view.displayMode = .singlePageContinuous"))
        #expect(preview.contains("case .unavailable"))

        #expect(loader.contains("private enum PreviewKind"))
        #expect(loader.contains("func filePreviewPayload("))
        #expect(loader.contains("func cancelFilePreview("))
        #expect(loader.contains("previewFlight?.task.cancel()"))
        #expect(composer.occurrences(of: "fullPreviewData: data") == 1)
        #expect(composer.contains("let fullPreviewData = data"))
        #expect(composer.contains("fullPreviewData: nil"))
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot.appending(path: path), encoding: .utf8)
    }
}

private extension String {
    func occurrences(of value: String) -> Int {
        components(separatedBy: value).count - 1
    }
}
