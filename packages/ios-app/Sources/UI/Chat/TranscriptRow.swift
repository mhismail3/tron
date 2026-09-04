import SwiftUI

private struct ChatMessageGrowthIdentity: Equatable {
    let partCount: Int
    let lastPartID: String?
    let textUTF16Length: Int
    let thinkingSegmentCount: Int
    let errorUTF16Length: Int
    let showsFooter: Bool

    init(parts: [ChatMessagePart], errorMessage: String?, showsFooter: Bool) {
        partCount = parts.count
        lastPartID = parts.last?.id
        textUTF16Length = parts.reduce(into: 0) { total, part in
            let addition = switch part {
            case .content(let content):
                content.text?.utf16.count ?? 0
            case .thinking(let run):
                run.segments.reduce(into: 0) { count, segment in
                    count = Self.addingWithoutOverflow(count, segment.text.utf16.count)
                }
            }
            total = Self.addingWithoutOverflow(total, addition)
        }
        thinkingSegmentCount = parts.reduce(into: 0) { total, part in
            guard case .thinking(let run) = part else { return }
            total = Self.addingWithoutOverflow(total, run.segments.count)
        }
        errorUTF16Length = errorMessage?.utf16.count ?? 0
        self.showsFooter = showsFooter
    }

    private static func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > Int.max - rhs ? Int.max : lhs + rhs
    }
}

enum UserPromptPresentationPolicy {
    static func visibleText(_ text: String?, hasAttachments: Bool = false) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(hasAttachments && ChatAttachmentEnvelopePolicy.isBounded(text)) else { return nil }
        return text
    }
}

enum AutomationPromptPresentationPolicy {
    static let originTitle = "Automation"
    static let operationNamespace = "automation:"

    static func visibleText(_ item: TranscriptItem) -> String? {
        UserPromptPresentationPolicy.visibleText(item.text)
    }

    /// Automation identity comes only from the exact Gateway-authored
    /// invocation receipt bound to this canonical user entry. Display titles
    /// are intentionally not identity: the owner and operation namespaces are
    /// durable UUID contracts. Missing or partial provenance fails closed to
    /// the ordinary user prompt renderer.
    static func admits(_ item: TranscriptItem) -> Bool {
        guard item.kind == .message,
              item.role == .user,
              let semantic = item.semantic,
              semantic.direction == .inboundContext,
              semantic.contextEffect == .modelInput,
              semantic.delivery == .stored,
              semantic.visibility == .visible,
              semantic.kind == .prompt || semantic.kind == .resourcePrompt,
              semantic.origin.kind == .gateway,
              semantic.origin.confidence == .boundary,
              let ownerId = semantic.origin.ownerId,
              UUID(uuidString: ownerId) != nil,
              let invocationId = semantic.invocationId,
              UUID(uuidString: invocationId) != nil,
              let operationId = semantic.operationId,
              operationId.hasPrefix(operationNamespace),
              UUID(uuidString: String(operationId.dropFirst(operationNamespace.count))) != nil else { return false }
        return true
    }
}

struct TranscriptRow: View, Equatable {
    let item: TranscriptItem
    var streaming = false
    var toolResults: [String: TranscriptItem] = [:]
    var rendersToolCalls = true
    var projectedMessageParts: [ChatMessagePart]? = nil
    var preparedText: ChatTextPreparationSnapshot = .empty
    var showsMessageFooter = true

    var body: some View {
        VStack(alignment: isTrailingSessionMessage ? .trailing : .leading, spacing: 4) {
            switch item.kind {
            case .message:
                if item.role == .assistant {
                    ChatIncrementalContentGrowthHost(
                        identity: ChatMessageGrowthIdentity(
                            parts: displayedMessageParts,
                            errorMessage: item.errorMessage,
                            showsFooter: showsMessageFooter
                        ),
                        streaming: streaming
                    ) {
                        message
                    }
                } else {
                    message
                }
            case .bash:
                ToolCard(data: ChatToolPresentation(
                    id: item.id,
                    title: "bash",
                    toolName: "bash",
                    subtitle: item.cancelled == true ? "Cancelled" : "Exit \(item.exitCode.map(String.init) ?? "—")",
                    request: .object(["command": .string(item.command ?? "")]),
                    response: nil,
                    content: item.output ?? "",
                    fallbackContent: nil,
                    error: false,
                    startedAt: item.startedAt,
                    completedAt: item.completedAt,
                    durationMs: item.durationMs,
                    lastProgressAt: item.completedAt,
                    progressSequence: nil,
                    outputTruncated: item.truncated == true
                ))
            case .customMessage:
                // Every projected custom_message is model input under Pi's
                // session semantics. It is not a tool result and is rendered
                // on the inbound edge with explicit producer provenance.
                InboundProducerMessageView(item: item)
            case .customEntry:
                if item.semantic?.kind == .command {
                    CommandLifecycleView(item: item)
                } else if let notification = ChatNotificationPresentation.canonical(item, globalOrdinal: nil) {
                    ChatNotificationView(presentation: notification)
                } else {
                    // appendEntry/custom entries are extension state, not chat
                    // content. Only typed Gateway receipts have a transcript
                    // presentation; unadapted state remains absent.
                    EmptyView()
                }
            case .compaction, .branchSummary, .modelChange, .thinkingChange, .label:
                if let notification = ChatNotificationPresentation.canonical(item, globalOrdinal: nil) {
                    ChatNotificationView(presentation: notification)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isTrailingSessionMessage ? .trailing : .leading)
    }

    private var isTrailingSessionMessage: Bool {
        item.role == .user || item.semantic?.direction == .inboundContext
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
        } else if AutomationPromptPresentationPolicy.admits(item) {
            AutomationPromptMessageView(item: item)
        } else {
            VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 4) {
                if let resource = item.semantic?.resourceInvocation {
                    CanonicalResourceChip(resource: resource)
                }
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
                                if let text = UserPromptPresentationPolicy.visibleText(
                                    part.text,
                                    hasAttachments: !displayedAttachments.isEmpty
                                ) {
                                    UserPromptText(text: text)
                                        .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                                        .padding(.top, ChatPromptContainerStyle.topPadding)
                                        .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                                        .modifier(UserPromptGlassModifier())
                                }
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
                        title: ChatProviderErrorPresentation.message(error),
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
    struct Cache {
        var intrinsicSize: CGSize?
        var fittedWidth: CGFloat?
        var fittedSize: CGSize?
    }

    let maxWidth: CGFloat

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return measurement(
            availableWidth: min(maxWidth, proposal.width ?? maxWidth),
            subview: subview,
            cache: &cache
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard let subview = subviews.first else { return }
        let fitted = measurement(
            availableWidth: min(maxWidth, bounds.width),
            subview: subview,
            cache: &cache
        )
        subview.place(
            at: CGPoint(x: bounds.maxX - fitted.width, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: fitted.width, height: fitted.height)
        )
    }

    private func measurement(
        availableWidth: CGFloat,
        subview: LayoutSubview,
        cache: inout Cache
    ) -> CGSize {
        let intrinsic: CGSize
        if let cached = cache.intrinsicSize {
            intrinsic = cached
        } else {
            intrinsic = subview.sizeThatFits(.unspecified)
            cache.intrinsicSize = intrinsic
        }
        let width = UserPromptTextLayoutPolicy.boundedContainerWidth(
            intrinsic: intrinsic.width,
            proposed: availableWidth,
            maximum: maxWidth
        )
        if cache.fittedWidth == width, let fitted = cache.fittedSize {
            return fitted
        }
        let measured = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let fitted = CGSize(width: width, height: measured.height)
        cache.fittedWidth = width
        cache.fittedSize = fitted
        return fitted
    }
}

struct UserPromptGlassModifier: ViewModifier {
    let accent: Color

    init(accent: Color = .tronEmerald) {
        self.accent = accent
    }

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
            .regular.tint(accent.opacity(ChatPromptContainerStyle.tintOpacity)),
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
        let inline = preparedInline
        VStack(alignment: .leading, spacing: 0) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(TronFont.body(11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            traceViewport(inline: inline)
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
        .overlay(alignment: .topLeading) { measurementProbe(inline: inline) }
        .tronManagedSheet(
            isPresented: $showingDetails,
            identity: "chat.thinking-trace.\(traceIdentity)"
        ) {
            ThinkingTraceDetailSheet(
                inline: inline,
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
    private func traceViewport(inline: MarkdownPresentation.Inline) -> some View {
        ZStack(alignment: .topLeading) {
            paragraph(inline: inline)
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

    private func paragraph(inline: MarkdownPresentation.Inline) -> some View {
        ChatStreamingInlineText(
            inline: inline,
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
        if allPrepared {
            return MarkdownPresentation.Inline(source: source, attributedString: attributed)
        }
        // Explicitly paged history can exceed the asynchronously warmed tail.
        // Lazily realized older thinking rows still receive the same exact
        // Markdown semantics through the bounded cold-parser fallback.
        return MarkdownPresentation.Inline(source: source)
    }

    private func measurementText(inline: MarkdownPresentation.Inline) -> some View {
        Text(inline.attributedString ?? AttributedString(inline.source))
            .font(TronFont.body(12))
            .italic()
            .lineSpacing(0)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func measurementProbe(inline: MarkdownPresentation.Inline) -> some View {
        VStack(spacing: 0) {
            measurementText(inline: inline)
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
            if ChatThinkingTraceLayoutPolicy.admitsMeasurement(
                current: contentHeight,
                candidate: metrics.contentHeight
            ) {
                contentHeight = metrics.contentHeight
            }
            if ChatThinkingTraceLayoutPolicy.admitsMeasurement(
                current: maximumHeight,
                candidate: metrics.maximumHeight
            ) {
                maximumHeight = metrics.maximumHeight
            }
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
    let inline: MarkdownPresentation.Inline
    let identity: String
    let streaming: Bool
    @Environment(\.dismiss) private var dismiss

    private let title = "Thinking"

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
    @Environment(\.tronPresentationActivity) private var presentationActivity
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
                        TronPulseLoadingIndicator(accent: .tronBlue, size: 18)
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
        .task(id: PresentationActivityTaskID(
            source: loadKey,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
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
        .tronManagedSheet(
            item: $previewRequest,
            identity: { "chat.image-preview.\($0.id)" }
        ) { request in
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
    @Environment(\.tronPresentationActivity) private var presentationActivity
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
        .task(id: PresentationActivityTaskID(
            source: identity,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication,
                  let identity,
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
        .tronManagedSheet(
            item: $previewRequest,
            identity: { "chat.file-preview.\($0.id)" }
        ) { request in
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
