import SwiftUI

struct TranscriptRow: View, Equatable {
    let item: TranscriptItem
    var streaming = false
    var toolResults: [String: TranscriptItem] = [:]
    var rendersToolCalls = true
    var projectedMessageParts: [ChatMessagePart]? = nil
    var preparedText: ChatTextPreparationSnapshot = .empty
    var showsMessageFooter = true

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
                title: item.toolLabel ?? item.toolName ?? "Tool result",
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
                            label: preparedText.hiddenThinkingLabel,
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
                                        identity: ChatTextPreparationKey.content(part),
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
                                        title: part.label ?? result.toolLabel ?? part.name ?? result.toolName ?? "Tool",
                                        subtitle: result.isError == true ? "Failed" : "Completed",
                                        content: result.text,
                                        error: result.isError == true,
                                        request: part.arguments,
                                        response: result.details,
                                        fallbackContent: result.text.isEmpty ? result.details : nil
                                    )
                                } else {
                                    ToolCard(
                                        title: part.label ?? part.name ?? "Tool",
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
                    Text(ModelDisplayFormatting.reference(provider: provider, model: modelName))
                        .font(TronFont.mono(10))
                        .foregroundStyle(Color.tronTextSecondary)
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
                            size: attachment.size,
                            blobID: part.blobId
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
        }
        .scrollClipDisabled()
        .defaultScrollAnchor(item.role == .user ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
        .padding(.vertical, item.role == .user ? 3 : 0)
        .accessibilityLabel("Prompt attachments")
    }

}

struct BoundedTrailingContentLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let availableWidth = min(maxWidth, proposal.width ?? maxWidth)
        let intrinsic = subview.sizeThatFits(.unspecified)
        let width = UserPromptTextLayoutPolicy.boundedContainerWidth(
            intrinsic: intrinsic.width,
            proposed: availableWidth,
            maximum: maxWidth
        )
        let fitted = subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: fitted.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let availableWidth = min(maxWidth, bounds.width)
        let intrinsic = subview.sizeThatFits(.unspecified)
        let width = UserPromptTextLayoutPolicy.boundedContainerWidth(
            intrinsic: intrinsic.width,
            proposed: availableWidth,
            maximum: maxWidth
        )
        let fitted = subview.sizeThatFits(ProposedViewSize(width: width, height: bounds.height))
        subview.place(
            at: CGPoint(x: bounds.maxX - width, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: fitted.height)
        )
    }
}

struct UserPromptGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: ChatPromptContainerStyle.cornerRadius,
            style: .continuous
        )
        // Measure once against the bounded proposal: short prompts retain
        // their intrinsic bubble width, while long prompts wrap immediately.
        // This replaces ViewThatFits without expanding every prompt to the
        // maximum width or swapping branches after a large paste.
        BoundedTrailingContentLayout(maxWidth: UserPromptTextLayoutPolicy.maximumWidth) {
            content.fixedSize(horizontal: false, vertical: true)
        }
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(ChatPromptContainerStyle.tintOpacity)),
            in: shape
        )
    }
}

private struct ThinkingBlock: View {
    let segments: [ChatThinkingSegment]
    let preparedText: ChatTextPreparationSnapshot
    let label: String?
    let animatesInsertion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var contentHeight: CGFloat = 0
    @State private var maximumHeight: CGFloat = 0
    @State private var showingDetails = false

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
    }

    private var isOverflowing: Bool {
        ChatThinkingTraceLayoutPolicy.isOverflowing(
            contentHeight: contentHeight,
            maximumHeight: maximumHeight
        )
    }

    private var traceHeight: CGFloat {
        guard maximumHeight > 0, contentHeight > 0 else {
            return ChatThinkingTraceLayoutPolicy.initialViewportHeight(lineCount: segments.count)
        }
        return ChatThinkingTraceLayoutPolicy.viewportHeight(
            contentHeight: contentHeight,
            maximumHeight: maximumHeight
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(TronFont.body(11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            traceViewport
                .frame(height: traceHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isOverflowing else { return }
                    showingDetails = true
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleParagraph)
        .accessibilityAddTraits(isOverflowing ? .isButton : [])
        .accessibilityHint(isOverflowing ? "Double-tap to view the full thinking trace" : "")
        .overlay(alignment: .topLeading) { measurementProbe }
        .sheet(isPresented: $showingDetails) {
            ThinkingTraceDetailSheet(
                label: label,
                inline: preparedInline,
                identity: traceIdentity,
                streaming: animatesInsertion
            )
        }
    }

    private var accessibleParagraph: String {
        let paragraph = segments.map(\.text).joined(separator: " ")
        guard let label, !label.isEmpty else { return paragraph }
        return "\(label). \(paragraph)"
    }

    private var traceIdentity: String {
        "thinking-run:\(segments.first?.id ?? "empty")"
    }

    /// The compact row is a tail projection, not a nested scroll surface:
    /// full content stays authoritative and measured while only the latest
    /// four measured lines are presented in the visible viewport.
    private var traceViewport: some View {
        ZStack(alignment: .topLeading) {
            paragraph
                .offset(y: -tailOffset)
        }
        .frame(height: traceHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(
            reduceMotion ? nil : .smooth(
                duration: ChatScrollCoordinator.liveGrowthAnimationDuration
            ),
            value: CGSize(width: traceHeight, height: tailOffset)
        )
        .clipped()
        .mask(tailMask)
        .accessibilityHidden(true)
    }

    private var tailOffset: CGFloat {
        ChatThinkingTraceLayoutPolicy.tailOffset(
            contentHeight: contentHeight,
            viewportHeight: traceHeight
        )
    }

    @ViewBuilder
    private var tailMask: some View {
        if ChatThinkingTraceLayoutPolicy.showsEarlierContent(
            contentHeight: contentHeight,
            maximumHeight: maximumHeight
        ) {
            let fadeHeight = min(20, max(1, traceHeight * 0.35))
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.38), location: 0),
                    .init(color: .black, location: min(1, fadeHeight / max(1, traceHeight))),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

    private var paragraph: some View {
        ChatStreamingInlineText(
            inline: preparedInline,
            identity: traceIdentity,
            baseColor: Color.tronTextSecondary,
            streaming: animatesInsertion
        )
        .font(TronFont.body(12))
        .italic()
        .lineSpacing(0)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var preparedInline: MarkdownPresentation.Inline {
        let source = segments.map(\.text).joined(separator: "\n")
        var attributed = AttributedString()
        var allPrepared = true
        for (index, segment) in segments.enumerated() {
            if index > 0 { attributed += AttributedString("\n") }
            guard let prepared = preparedText.thinkingInline(
                identity: segment.id,
                source: segment.text
            ), let value = prepared.attributedString else {
                allPrepared = false
                break
            }
            attributed += value
        }
        return MarkdownPresentation.Inline(
            source: source,
            attributedString: allPrepared ? attributed : nil
        )
    }

    private var measurementText: some View {
        Text(preparedInline.attributedString ?? AttributedString(preparedInline.source))
            .font(TronFont.body(12))
            .italic()
            .lineSpacing(0)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var measurementProbe: some View {
        VStack(spacing: 0) {
            measurementText
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ChatThinkingTraceMetricsKey.self,
                            value: ChatThinkingTraceMetrics(contentHeight: geometry.size.height)
                        )
                    }
                }
            Text("Ag\nAg\nAg\nAg")
                .font(TronFont.body(12))
                .italic()
                .lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ChatThinkingTraceMetricsKey.self,
                            value: ChatThinkingTraceMetrics(maximumHeight: geometry.size.height)
                        )
                    }
                }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onPreferenceChange(ChatThinkingTraceMetricsKey.self) { metrics in
            contentHeight = metrics.contentHeight
            maximumHeight = metrics.maximumHeight
        }
    }
}

private struct ChatThinkingTraceMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var maximumHeight: CGFloat = 0

    init(contentHeight: CGFloat = 0, maximumHeight: CGFloat = 0) {
        self.contentHeight = contentHeight
        self.maximumHeight = maximumHeight
    }
}

private struct ChatThinkingTraceMetricsKey: PreferenceKey {
    static let defaultValue = ChatThinkingTraceMetrics()

    static func reduce(value: inout ChatThinkingTraceMetrics, nextValue: () -> ChatThinkingTraceMetrics) {
        let next = nextValue()
        if next.contentHeight > 0 { value.contentHeight = next.contentHeight }
        if next.maximumHeight > 0 { value.maximumHeight = next.maximumHeight }
    }
}

private struct ThinkingTraceDetailSheet: View {
    let label: String?
    let inline: MarkdownPresentation.Inline
    let identity: String
    let streaming: Bool
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        label?.isEmpty == false ? label! : "Thinking trace"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        ChatStreamingInlineText(
                            inline: inline,
                            identity: "detail:\(identity)",
                            baseColor: Color.tronTextSecondary,
                            // The detail surface always shows the complete
                            // authoritative trace. It must never lag behind
                            // the source merely because the compact row fades.
                            streaming: false
                        )
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .id("thinking-detail-bottom")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top)
                .tronScrollEdgeChrome()
                .onAppear {
                    proxy.scrollTo("thinking-detail-bottom", anchor: .top)
                }
                .onChange(of: inline.source) { _, _ in
                    guard streaming else { return }
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo("thinking-detail-bottom", anchor: .bottom)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: title, accent: .tronEmerald)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
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
        guard let identity else { return nil }
        if thumbnailIdentity == identity, let thumbnail { return thumbnail }
        return model.chatMedia.cachedThumbnail(for: identity)
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
        // The slot is stable from projection install; thumbnail replacement
        // must not animate as a second chip insertion during prompt settlement.
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
    @Environment(AppModel.self) private var model
    let name: String
    let mimeType: String
    let size: Int?
    let blobID: String?
    @State private var thumbnail: UIImage?
    @State private var thumbnailIdentity: ChatMediaIdentity?
    @State private var previewRequest: FilePreviewRequest?

    private struct FilePreviewRequest: Identifiable {
        let id = UUID()
        let identity: ChatMediaIdentity?
    }

    private var identity: ChatMediaIdentity? {
        blobID.flatMap { model.chatMediaIdentity(blobID: $0) }
    }

    private var currentThumbnail: UIImage? {
        guard let identity else { return nil }
        if thumbnailIdentity == identity, let thumbnail { return thumbnail }
        return model.chatMedia.cachedThumbnail(for: identity)
    }

    var body: some View {
        Button {
            previewRequest = FilePreviewRequest(identity: identity)
        } label: {
            AttachmentThumbnailSurface(image: currentThumbnail, name: name, mimeType: mimeType)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File attachment, \(name), \(detail)")
        .accessibilityHint("Opens the file preview")
        .task(id: identity) {
            guard let identity,
                  thumbnailIdentity != identity || thumbnail == nil else { return }
            guard let loaded = try? await model.chatMedia.fileThumbnail(
                for: identity,
                name: name,
                mimeType: mimeType
            ), !Task.isCancelled, self.identity == identity else { return }
            thumbnail = loaded
            thumbnailIdentity = identity
        }
        .onChange(of: identity) { _, _ in previewRequest = nil }
        .sheet(item: $previewRequest) { request in
            AttachmentFilePreviewSheet(
                name: name,
                mimeType: mimeType,
                source: request.identity.map {
                    .remote(identity: $0, leaseID: request.id)
                } ?? .unavailable
            )
        }
    }

    private var detail: String {
        let kind = mimeType.split(separator: "/").last.map(String.init)?.uppercased() ?? "FILE"
        guard let size else { return kind }
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }
}
