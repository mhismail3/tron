import SwiftUI
import TronMobileCore

private struct ChatMessageGrowthIdentity: Equatable, Sendable {
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
    /// Display only: invocation arguments retain the user's original text even
    /// after the runtime expands a template. Never infer or strip template
    /// content by matching strings, and never use this preview for submission.
    static func promptDisplayText(_ resource: ComposerResourceInvocation?) -> String? {
        guard let resource, resource.source == .prompt else { return nil }
        return resource.arguments
    }

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
        UserPromptPresentationPolicy.visibleText(
            UserPromptPresentationPolicy.promptDisplayText(item.semantic?.resourceInvocation) ?? item.text
        )
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

/// What `TranscriptRow` has to show for a projected item. The kernel asks this
/// before it installs a row, because a row whose body is `EmptyView` still costs
/// a padded lazy child: it takes part in realization, entrance bookkeeping and
/// tail anchoring while showing nothing. A `customEntry` that is not a command
/// lifecycle, and a summary/model/thinking/label receipt whose typed
/// presentation the adapter declined, render nothing, so they are not rows. It
/// is the same branch the row itself takes, kept next to it so the two cannot
/// drift.
enum TranscriptRowPresentationPolicy {
    static func rendersRow(for item: TranscriptItem) -> Bool {
        switch item.kind {
        case .message, .bash, .customMessage: true
        case .customEntry: item.semantic?.kind == .command
        case .compaction, .branchSummary, .modelChange, .thinkingChange, .label: false
        }
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
                    // presentation; unadapted state remains absent, and
                    // `TranscriptRowPresentationPolicy` keeps the kernel from
                    // installing the empty row.
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
            ToolCard(data: ChatToolPresentation(
                id: item.toolCallId ?? item.id,
                title: item.toolLabel ?? item.toolName ?? "Tool result",
                toolName: item.toolName,
                subtitle: item.isError == true ? "Failed" : "Completed",
                request: nil,
                response: item.details,
                content: item.text,
                fallbackContent: item.text.isEmpty ? item.details : nil,
                error: item.isError == true,
                startedAt: item.startedAt,
                completedAt: item.completedAt ?? item.timestamp,
                durationMs: item.durationMs,
                lastProgressAt: item.lastProgressAt,
                progressSequence: item.progressSequence,
                display: item.display,
                extensionOrigin: item.extensionOrigin,
                toolSegmentId: item.toolSegmentId
            ))
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
                                        .modifier(ChatMessageCopyMenu(text: text))
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
                                    ToolCard(data: ChatToolPresentation(
                                        id: callID,
                                        title: part.label ?? result.toolLabel ?? part.name ?? result.toolName ?? "Tool",
                                        toolName: part.name ?? result.toolName,
                                        subtitle: result.isError == true ? "Failed" : "Completed",
                                        request: part.arguments,
                                        response: result.details,
                                        content: result.text,
                                        fallbackContent: result.text.isEmpty ? result.details : nil,
                                        error: result.isError == true,
                                        startedAt: result.startedAt ?? item.timestamp,
                                        completedAt: result.completedAt ?? result.timestamp,
                                        durationMs: result.durationMs,
                                        lastProgressAt: result.lastProgressAt,
                                        progressSequence: result.progressSequence,
                                        display: result.display,
                                        extensionOrigin: result.extensionOrigin,
                                        toolSegmentId: part.toolSegmentId ?? result.toolSegmentId,
                                        groupId: part.groupId,
                                        groupIndex: part.groupIndex,
                                        groupCount: part.groupCount,
                                        groupFinalized: part.groupFinalized
                                    ))
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
                        detailBody: error,
                        icon: "exclamationmark.triangle.fill",
                        tone: .error,
                        expandsOnTruncation: true,
                        animatesEntrance: streaming
                    )
                }
                if let modelAttribution {
                    Text(modelAttribution)
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

    var modelAttribution: String? {
        // Message settlement, not whole-turn idleness, owns attribution. The
        // Markdown reveal also settles at this same streaming boundary.
        guard !streaming, showsMessageFooter,
              item.role == .assistant,
              displayedMessageParts.contains(where: { part in
                  if case .content(let content) = part {
                      return content.type == .text && !(content.text ?? "").isEmpty
                  }
                  return false
              }),
              let provider = item.provider,
              let modelName = item.modelId else { return nil }
        return ModelDisplayFormatting.reference(provider: provider, model: modelName)
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
    @Environment(\.chatTranscriptSheetRoutes) private var sheetRoutes
    #if HOSTED_TEST
    @Environment(\.chatHostedRecorder) private var hostedRecorder
    #endif

    /// The paragraph's measured height and the four reference lines' measured
    /// height. Each has one purpose, and neither can move a mounted row: the
    /// reference height decides the overflow flag (the tail mask, the tap target
    /// and the accessibility trait), and the content height is the trace
    /// layout's animatable input, which is how the viewport and the tail offset
    /// interpolate together while the trace streams. The layout measures its own
    /// subviews in the pass that places them, so its first frame is exact.
    @State private var contentHeight: CGFloat = 0
    @State private var referenceHeight: CGFloat = 0
    /// Whether a measurement has landed for this trace. A mount's first
    /// measurement is the height the layout already placed the trace at, so the
    /// update that publishes it is not growth and must not animate; every later
    /// change is the trace's own growth.
    @State private var hasMeasuredTrace = false

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
            maximumHeight: referenceHeight
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
                .onTapGesture { openDetails() }
                #if HOSTED_TEST
                // The detail action a hosted test activates; a tap cannot be
                // injected into a SwiftUI gesture.
                .modifier(HostedToolActionProbeModifier(
                    id: "thinking-detail:\(traceIdentity)",
                    action: openDetails
                ))
                #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleParagraph)
        .accessibilityAddTraits(admitsDetailAction ? .isButton : [])
        .accessibilityHint(admitsDetailAction ? "Double-tap to view the full thinking trace" : "")
    }

    /// The full trace belongs to the transcript, not to this row: streaming
    /// pushes the row out of lazy realization, and the sheet must outlive it.
    /// The route carries the trace's identity and the content this row resolved,
    /// and the sheet follows the install's own content from there.
    private func openDetails() {
        guard isOverflowing, let sheetRoutes else { return }
        sheetRoutes.present(.thinkingTrace(ChatThinkingTraceSheetRoute(
            identity: traceIdentity,
            opened: ChatThinkingTraceContent(
                segments: segments,
                preparedText: preparedText,
                streaming: animatesInsertion
            )
        )))
    }

    /// A row rendered without a transcript host offers no detail action, so its
    /// trait and hint never claim one.
    private var admitsDetailAction: Bool {
        isOverflowing && sheetRoutes != nil
    }

    private var accessibleParagraph: String {
        let paragraph = segments.map(\.text).joined(separator: " ")
        guard let label, !label.isEmpty else { return paragraph }
        return "\(label). \(paragraph)"
    }

    private var traceIdentity: String {
        ChatThinkingTraceContent.identity(of: segments)
    }

    /// The compact row is a tail projection, not a nested scroll surface:
    /// full content stays authoritative while only the latest four measured
    /// lines are presented in the visible viewport. The tail layout measures
    /// both subviews in the pass that places them, so a freshly mounted row is
    /// already at its final height and only the trace's own source growth
    /// animates.
    private func traceViewport(inline: MarkdownPresentation.Inline) -> some View {
        ThinkingTailLayout(contentHeight: contentHeight) {
            paragraph(inline: inline)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                    installMeasurement(&contentHeight, measured)
                }
                #if HOSTED_TEST
                // Where the layout placed the paragraph in the viewport it owns.
                // Its top edge is the tail offset the trace slides by.
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .named(Self.traceMotionSpace)).minY
                } action: { offset in
                    hostedRecorder?.recorder?.recordThinkingTraceParagraphOffset(
                        id: traceIdentity,
                        offset: offset
                    )
                }
                #endif
            referenceLines
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                    installMeasurement(&referenceHeight, measured)
                }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(
            reduceMotion || !hasMeasuredTrace
                ? nil
                : .smooth(duration: ChatScrollCoordinator.liveGrowthAnimationDuration),
            value: animatedTraceMotion
        )
        .clipped()
        .mask(tailMask)
        .onChange(of: contentHeight, initial: true) { _, measured in
            guard measured > 0, !hasMeasuredTrace else { return }
            hasMeasuredTrace = true
        }
        #if HOSTED_TEST
        .coordinateSpace(name: Self.traceMotionSpace)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            hostedRecorder?.recorder?.recordThinkingTraceViewport(
                id: traceIdentity,
                height: height
            )
        }
        .background {
            ChatHostedThinkingTraceProbe(
                id: traceIdentity,
                contentHeight: contentHeight,
                referenceHeight: referenceHeight,
                overflowing: isOverflowing
            )
        }
        #endif
        .accessibilityHidden(true)
    }

    #if HOSTED_TEST
    private static let traceMotionSpace = "chat-thinking-trace-motion"
    #endif

    /// The one value whose change animates this trace: the viewport it presents
    /// and the tail offset it slides by, both derived from the content height the
    /// layout interpolates. It is the same pair the frame-and-offset animation
    /// this replaces keyed on, and it matters that it is derived from the
    /// measurement rather than from the trace's source: the source grows in the
    /// install that suppresses row animations, while the measurement lands in the
    /// layout pass that must interpolate.
    private var animatedTraceMotion: CGSize {
        guard contentHeight > 0, referenceHeight > 0 else { return .zero }
        let viewport = ChatThinkingTraceLayoutPolicy.viewportHeight(
            contentHeight: contentHeight,
            maximumHeight: referenceHeight
        )
        return CGSize(
            width: viewport,
            height: ChatThinkingTraceLayoutPolicy.tailOffset(
                contentHeight: contentHeight,
                viewportHeight: viewport
            )
        )
    }

    private func installMeasurement(_ storage: inout CGFloat, _ measured: CGFloat) {
        guard ChatThinkingTraceLayoutPolicy.admitsMeasurement(
            current: storage,
            candidate: measured
        ) else { return }
        storage = measured
    }

    /// The viewport's reference height: the four measured lines the policy
    /// bounds the compact trace to.
    private var referenceLines: some View {
        Text(Array(
            repeating: "Ag",
            count: ChatThinkingTraceLayoutPolicy.maximumLines
        ).joined(separator: "\n"))
        .font(TronFont.body(12))
        .italic()
        .lineSpacing(0)
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var tailMask: some View {
        if ChatThinkingTraceLayoutPolicy.showsEarlierContent(
            contentHeight: contentHeight,
            maximumHeight: referenceHeight
        ) {
            let fadeHeight = min(20, max(1, viewportHeight * 0.35))
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.38), location: 0),
                    .init(color: .black, location: min(1, fadeHeight / max(1, viewportHeight))),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.black
        }
    }

    private var viewportHeight: CGFloat {
        ChatThinkingTraceLayoutPolicy.viewportHeight(
            contentHeight: contentHeight,
            maximumHeight: referenceHeight
        )
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
        ChatThinkingTraceContent.inline(of: segments, preparedText: preparedText)
    }
}

/// The compact thinking trace: the paragraph clipped to four measured reference
/// lines, scrolled to its tail. Both subviews are measured in the pass that
/// places them, so a mounted row is at its final height in its first frame —
/// the estimate this replaces left the first mount of a trace 50 pt short and
/// only a later remount reached the measured viewport.
///
/// The viewport height and the paragraph's tail offset are both derived from one
/// content height, exactly as the frame and offset this replaces were: while the
/// trace streams, the layout's animatable `contentHeight` interpolates and the
/// row grows continuously, and a trace past four lines slides its tail instead
/// of jumping a line per token. A zero `contentHeight` is the first pass of a
/// mount: the layout then uses the paragraph height it just measured, so no
/// estimate is ever committed.
private struct ThinkingTailLayout: Layout, Animatable {
    /// The trace's content height to interpolate, or zero on the first pass of a
    /// mount, where the layout's own synchronous measurement is exact.
    var contentHeight: CGFloat

    var animatableData: CGFloat {
        get { contentHeight }
        set { contentHeight = newValue }
    }

    struct Cache {
        var width: CGFloat?
        var paragraphHeight: CGFloat?
        var referenceHeight: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // A payload or Dynamic Type change invalidates both measurements;
        // animating `contentHeight` alone does not, so one exact measurement
        // serves every frame of the growth interpolation.
        cache = Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? Self.naturalWidth(subviews)
        let measured = measure(width: width, subviews: subviews, cache: &cache)
        return CGSize(width: width, height: viewportHeight(measured))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let measured = measure(width: bounds.width, subviews: subviews, cache: &cache)
        let viewport = viewportHeight(measured)
        // The paragraph keeps its natural height and is offset so its tail —
        // the newest text — is what the viewport shows. The offset comes from the
        // same content height as the viewport, so both move in one interpolation:
        // an offset derived from the paragraph's own, already-measured height
        // would jump a line per token while the viewport animated.
        subviews[0].place(
            at: CGPoint(
                x: bounds.minX,
                y: bounds.minY - ChatThinkingTraceLayoutPolicy.tailOffset(
                    contentHeight: contentHeight(measured),
                    viewportHeight: viewport
                )
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: measured.paragraph)
        )
        guard subviews.count > 1 else { return }
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: measured.reference)
        )
    }

    private func viewportHeight(_ measured: (paragraph: CGFloat, reference: CGFloat)) -> CGFloat {
        ChatThinkingTraceLayoutPolicy.viewportHeight(
            contentHeight: contentHeight(measured),
            maximumHeight: measured.reference
        )
    }

    /// The one height the viewport and the tail offset are derived from: the
    /// interpolated content height, or — on the first pass of a mount, before any
    /// measurement has been published — the exact height of the paragraph the
    /// same pass measured.
    private func contentHeight(_ measured: (paragraph: CGFloat, reference: CGFloat)) -> CGFloat {
        contentHeight > 0 ? contentHeight : measured.paragraph
    }

    private func measure(
        width: CGFloat,
        subviews: Subviews,
        cache: inout Cache
    ) -> (paragraph: CGFloat, reference: CGFloat) {
        if cache.width == width,
           let paragraph = cache.paragraphHeight,
           let reference = cache.referenceHeight {
            return (paragraph, reference)
        }
        let measurement = ProposedViewSize(width: width, height: nil)
        let paragraph = subviews[0].sizeThatFits(measurement).height
        let reference = subviews.count > 1
            ? subviews[1].sizeThatFits(measurement).height
            : 0
        cache.width = width
        cache.paragraphHeight = paragraph
        cache.referenceHeight = reference
        return (paragraph, reference)
    }

    private static func naturalWidth(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }
}

/// The expanded thinking trace. It starts at the beginning of the trace unless
/// the trace is still arriving, in which case it follows the tail.
struct ThinkingTraceDetailSheet: View {
    let inline: MarkdownPresentation.Inline
    let identity: String
    let streaming: Bool
    @Environment(\.dismiss) private var dismiss
    #if HOSTED_TEST
    @Environment(\.chatHostedRecorder) private var hostedRecorder
    #endif

    private let title = "Thinking"
    /// Scroll target for tail following; a completed trace never scrolls here.
    private static let traceID = "thinking-detail-trace"

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
                        .id(Self.traceID)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top)
                .tronScrollEdgeChrome()
                #if HOSTED_TEST
                // What this sheet is actually showing: its source length and its
                // own scroll position, recorded per scroll-geometry change.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                    hostedRecorder?.recorder?.recordThinkingSheet(
                        id: identity,
                        sourceUTF16Length: inline.source.utf16.count,
                        scrollOffset: offset
                    )
                }
                #endif
                .onAppear {
                    // A completed trace starts at its beginning. Scrolling to it
                    // here would drop the content padding out of view and start
                    // the sheet one row down under the top blur.
                    guard streaming else { return }
                    proxy.scrollTo(Self.traceID, anchor: .bottom)
                }
                .onChange(of: inline.source) { _, _ in
                    guard streaming else { return }
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        proxy.scrollTo(Self.traceID, anchor: .bottom)
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
