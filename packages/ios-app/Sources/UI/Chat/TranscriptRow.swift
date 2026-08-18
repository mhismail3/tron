import SwiftUI

struct TranscriptRow: View, Equatable {
    let item: TranscriptItem
    var streaming = false
    var toolResults: [String: TranscriptItem] = [:]
    var rendersToolCalls = true
    var projectedMessageParts: [ChatMessagePart]? = nil
    var preparedText: ChatTextPreparationSnapshot = .empty
    var showsMessageFooter = true
    var hiddenThinkingLabel: String? = nil

    var body: some View {
        VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 4) {
            switch item.kind {
            case .message:
                message
            case .bash:
                ToolCard(
                    title: "bash",
                    subtitle: item.cancelled == true ? "Cancelled" : "Exit \(item.exitCode.map(String.init) ?? "—")",
                    content: item.output ?? "",
                    request: .object(["command": .string(item.command ?? "")]),
                    outputTruncated: item.truncated == true
                )
            case .customMessage:
                ToolCard(
                    title: item.customType ?? "Extension",
                    subtitle: "Extension message",
                    content: item.text,
                    response: item.details,
                    fallbackContent: item.text.isEmpty ? item.details : nil
                )
            case .customEntry:
                ToolCard(
                    title: item.customType ?? "Extension state",
                    subtitle: "Extension state",
                    content: "",
                    response: item.customData,
                    fallbackContent: item.customData
                )
            case .compaction, .branchSummary, .modelChange, .thinkingChange, .label:
                if let notification = ChatNotificationPresentation.canonical(item, globalOrdinal: nil) {
                    ChatNotificationView(presentation: notification)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
    }

    @ViewBuilder private var message: some View {
        if item.role == .toolResult {
            ToolCard(
                title: item.toolName ?? "Tool result",
                subtitle: item.isError == true ? "Failed" : "Completed",
                content: item.text,
                error: item.isError == true,
                response: item.details,
                fallbackContent: item.text.isEmpty ? item.details : nil
            )
        } else {
            VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 4) {
                if !displayedAttachments.isEmpty {
                    attachmentStrip
                }
                ForEach(displayedMessageParts) { presentation in
                    switch presentation {
                    case .thinking(let run):
                        ThinkingBlock(
                            segments: run.segments,
                            preparedText: preparedText,
                            label: hiddenThinkingLabel,
                            animatesInsertion: streaming
                        )
                        // Keep the incremental visibility ledger attached to
                        // the logical thinking run, not its position among
                        // parts that may be added while the response streams.
                        .id(run.id)
                    case .content(let part):
                        switch part.type {
                        case .text:
                            if part.attachment != nil {
                                EmptyView() // Presented together above the prompt text.
                            } else if item.role == .user {
                                UserPromptText(text: part.text ?? "")
                                    .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                                    .padding(.top, ChatPromptContainerStyle.topPadding)
                                    .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                                    .modifier(UserPromptGlassModifier())
                            } else {
                                MarkdownText(
                                    text: part.text ?? "",
                                    document: preparedText.markdownDocument(
                                        identity: part.id,
                                        source: part.text ?? ""
                                    ),
                                    streaming: streaming
                                )
                            }
                        case .thinking:
                            EmptyView() // Adjacent thinking is projected as one run above.
                        case .image:
                            EmptyView() // Presented together above the prompt text.
                        case .toolCall:
                            if rendersToolCalls {
                                if let callID = part.toolCallId, let result = toolResults[callID] {
                                    ToolCard(
                                        title: part.name ?? result.toolName ?? "Tool",
                                        subtitle: result.isError == true ? "Failed" : "Completed",
                                        content: result.text,
                                        error: result.isError == true,
                                        request: part.arguments,
                                        response: result.details,
                                        fallbackContent: result.text.isEmpty ? result.details : nil
                                    )
                                } else {
                                    ToolCard(
                                        title: part.name ?? "Tool",
                                        subtitle: "Invocation",
                                        content: "",
                                        request: part.arguments,
                                        fallbackContent: part.arguments
                                    )
                                }
                            }
                        }
                    }
                }
                if showsMessageFooter, let error = item.errorMessage, !error.isEmpty {
                    TranscriptNotice(
                        title: error,
                        icon: "exclamationmark.triangle.fill",
                        tone: .error,
                        animatesEntrance: streaming
                    )
                }
                if showsMessageFooter,
                   item.role == .assistant,
                   displayedMessageParts.contains(where: { part in
                       if case .content(let content) = part {
                           return content.type == .text && !(content.text ?? "").isEmpty
                       }
                       return false
                   }),
                   let provider = item.provider,
                   let modelName = item.modelId {
                    Text("\(provider) / \(modelName)").font(TronFont.mono(10)).foregroundStyle(Color.tronTextSecondary)
                }
            }
            .padding(.horizontal, item.role == .user ? 0 : 2)
            .frame(
                maxWidth: .infinity,
                alignment: item.role == .user ? .topTrailing : .topLeading
            )
        }
    }

    private var displayedMessageParts: [ChatMessagePart] {
        projectedMessageParts ?? ChatTranscriptPresentation.messageParts(in: item)
    }

    private var displayedAttachments: [ContentPart] {
        displayedMessageParts.compactMap { part in
            guard case .content(let content) = part,
                  content.type == .image || content.attachment != nil else { return nil }
            return content
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(displayedAttachments) { part in
                    if part.type == .image, let id = part.blobId {
                        TranscriptImageChip(blobID: id)
                    } else if let attachment = part.attachment {
                        TranscriptFileChip(
                            name: attachment.name,
                            mimeType: attachment.mimeType,
                            size: attachment.size
                        )
                    }
                }
            }
        }
        .scrollClipDisabled()
        .defaultScrollAnchor(item.role == .user ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
        .padding(.vertical, item.role == .user ? 3 : 0)
        .accessibilityLabel("Prompt attachments")
    }

}

struct UserPromptGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: ChatPromptContainerStyle.cornerRadius,
            style: .continuous
        )
        ViewThatFits(in: .horizontal) {
            content
                .fixedSize(horizontal: true, vertical: false)
                .glassEffect(
                    .regular.tint(Color.tronEmerald.opacity(ChatPromptContainerStyle.tintOpacity)),
                    in: shape
                )
            content
                .glassEffect(
                    .regular.tint(Color.tronEmerald.opacity(ChatPromptContainerStyle.tintOpacity)),
                    in: shape
                )
        }
        .frame(maxWidth: UserPromptTextLayoutPolicy.maximumWidth, alignment: .trailing)
    }
}

private struct ThinkingBlock: View {
    let segments: [ChatThinkingSegment]
    let preparedText: ChatTextPreparationSnapshot
    let label: String?
    let animatesInsertion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleSegmentIDs: Set<String>

    init(
        segments: [ChatThinkingSegment],
        preparedText: ChatTextPreparationSnapshot,
        label: String?,
        animatesInsertion: Bool
    ) {
        self.segments = segments
        self.preparedText = preparedText
        self.label = label
        self.animatesInsertion = animatesInsertion
        _visibleSegmentIDs = State(initialValue: animatesInsertion ? [] : Set(segments.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(TronFont.body(11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            paragraph
                .font(TronFont.body(12))
                .italic()
                .lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleParagraph)
        .task(id: segments.map(\.id)) { await revealNewSegments() }
    }

    private var paragraph: Text {
        segments.enumerated().reduce(Text("")) { paragraph, element in
            let (index, segment) = element
            let separator = index == 0 ? Text("") : Text(" ")
            let renderedSegment = rendered(segment)
                .foregroundColor(Color.tronTextSecondary.opacity(segmentOpacity(segment.id)))
            return Text("\(paragraph)\(separator)\(renderedSegment)")
        }
    }

    private func rendered(_ segment: ChatThinkingSegment) -> Text {
        if let prepared = preparedText.thinkingInline(
            identity: segment.id,
            source: segment.text
        ) {
            if let attributed = prepared.attributedString { return Text(attributed) }
            return Text(prepared.source)
        }
        guard let attributed = try? AttributedString(
            markdown: segment.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return Text(segment.text) }
        return Text(attributed)
    }

    private var accessibleParagraph: String {
        let paragraph = segments.map(\.text).joined(separator: " ")
        guard let label, !label.isEmpty else { return paragraph }
        return "\(label). \(paragraph)"
    }

    private func segmentOpacity(_ id: String) -> Double {
        !animatesInsertion || reduceMotion || visibleSegmentIDs.contains(id) ? 1 : 0
    }

    @MainActor private func revealNewSegments() async {
        let currentIDs = Set(segments.map(\.id))
        visibleSegmentIDs.formIntersection(currentIDs)
        let hiddenIDs = segments.map(\.id).filter { !visibleSegmentIDs.contains($0) }
        guard animatesInsertion, !reduceMotion else {
            visibleSegmentIDs.formUnion(hiddenIDs)
            return
        }

        for id in hiddenIDs {
            guard !Task.isCancelled else { return }
            await Task.yield()
            withAnimation(.easeOut(duration: 0.28)) {
                _ = visibleSegmentIDs.insert(id)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }
}

private struct MarkdownText: View {
    let text: String
    let document: MarkdownPresentation.Document?
    let streaming: Bool

    @ViewBuilder var body: some View {
        if let document { TronMarkdownView(document: document, streaming: streaming) }
        else { TronMarkdownView(text: text, streaming: streaming) }
    }
}

private struct TranscriptImageChip: View {
    private struct LoadKey: Hashable {
        let identity: ChatMediaIdentity?
        let attempt: Int
    }

    private struct PreviewRequest: Identifiable {
        let identity: ChatMediaIdentity
        let leaseID: UUID
        let initialImage: UIImage

        var id: UUID { leaseID }
    }

    @Environment(AppModel.self) private var model
    let blobID: String
    @State private var thumbnail: UIImage?
    @State private var thumbnailIdentity: ChatMediaIdentity?
    @State private var previewImage: UIImage?
    @State private var previewRequest: PreviewRequest?
    @State private var failedLoadKey: LoadKey?
    @State private var loadAttempt = 0

    private var identity: ChatMediaIdentity? {
        model.chatMediaIdentity(blobID: blobID)
    }

    private var currentThumbnail: UIImage? {
        thumbnailIdentity == identity ? thumbnail : nil
    }

    private var loadKey: LoadKey {
        LoadKey(identity: identity, attempt: loadAttempt)
    }

    private var loadFailed: Bool {
        failedLoadKey == loadKey
    }

    var body: some View {
        Button {
            if let currentThumbnail, let identity {
                previewImage = currentThumbnail
                previewRequest = PreviewRequest(
                    identity: identity,
                    leaseID: UUID(),
                    initialImage: currentThumbnail
                )
            } else if loadFailed {
                loadAttempt &+= 1
            }
        } label: {
            Group {
                if let currentThumbnail {
                    Image(uiImage: currentThumbnail)
                        .resizable()
                        .scaledToFill()
                } else if loadFailed {
                    ZStack {
                        Color.tronBlue.opacity(0.10)
                        Image(systemName: "arrow.clockwise")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronBlue)
                    }
                } else {
                    ZStack {
                        Color.tronBlue.opacity(0.10)
                        ProgressView().controlSize(.mini).tint(.tronBlue)
                    }
                }
            }
            .frame(width: 64, height: 64)
            .clipped()
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronBlue.opacity(0.18)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
        .accessibilityLabel(loadFailed ? "Image attachment unavailable, retry" : "Image attachment")
        .task(id: loadKey) {
            let requestedKey = loadKey
            guard let identity = requestedKey.identity else {
                failedLoadKey = requestedKey
                return
            }
            guard thumbnailIdentity != identity || thumbnail == nil else { return }
            do {
                let loaded = try await model.chatMedia.thumbnail(for: identity)
                guard !Task.isCancelled, self.identity == identity else { return }
                thumbnail = loaded
                thumbnailIdentity = identity
                if failedLoadKey == requestedKey { failedLoadKey = nil }
            } catch {
                guard !Task.isCancelled, loadKey == requestedKey else { return }
                failedLoadKey = requestedKey
            }
        }
        .onChange(of: identity) { _, _ in
            previewImage = nil
            previewRequest = nil
        }
        .accessibilityHint(currentThumbnail == nil ? "Loads the unavailable image again" : "Opens a photo preview")
        .sheet(item: $previewRequest) { request in
            AttachmentImagePreviewSheet(image: previewImage ?? request.initialImage)
                .task(id: request.id) {
                    guard let full = try? await model.chatMedia.fullPreview(
                        for: request.identity,
                        leaseID: request.leaseID
                    ), !Task.isCancelled,
                       previewRequest?.id == request.id,
                       self.identity == request.identity else { return }
                    previewImage = full
                }
                .onDisappear {
                    model.chatMedia.cancelFullPreview(
                        for: request.identity,
                        leaseID: request.leaseID
                    )
                    if previewRequest?.id == request.id { previewRequest = nil }
                    previewImage = nil
                }
        }
    }
}

struct TranscriptFileChip: View {
    let name: String
    let mimeType: String
    let size: Int?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text.fill")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                .foregroundStyle(Color.tronBlue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 176, height: 64, alignment: .leading)
        .glassEffect(
            .regular.tint(Color.tronBlue.opacity(0.18)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("File attachment, \(name), \(detail)")
    }

    private var detail: String {
        let kind = mimeType.split(separator: "/").last.map(String.init)?.uppercased() ?? "FILE"
        guard let size else { return kind }
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }
}
