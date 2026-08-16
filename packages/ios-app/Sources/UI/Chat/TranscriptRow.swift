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
                    case .content(let part):
                        switch part.type {
                        case .text:
                            if part.attachment != nil {
                                EmptyView() // Presented together above the prompt text.
                            } else if item.role == .user {
                                UserPromptText(text: part.text ?? "")
                                    .padding(.leading, UserPromptTextLayoutPolicy.leadingInset)
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
                maxWidth: item.role == .user
                    ? UserPromptTextLayoutPolicy.maximumWidth
                    : .infinity,
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
        .accessibilityLabel("Prompt attachments")
    }

}

/// Shared compact visual treatment for transcript navigation actions.
/// The glass remains content-sized while the owning button supplies a separate
/// 44-point semantic target.
struct ChatTranscriptPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        ChatCompactPillSurface(tone: .accent, material: .glass, interactive: true) {
            content
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronAccentText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension View {
    func chatTranscriptPill() -> some View {
        modifier(ChatTranscriptPillModifier())
    }
}

/// One visual language for transcript events that are not conversation turns.
/// Detail-bearing events are buttons with Liquid Glass; informational events
/// remain noninteractive and flat while retaining the same capsule geometry.
struct ChatNotificationView: View {
    let presentation: ChatNotificationPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingDetail = false

    var body: some View {
        Group {
            if presentation.hasDetailSheet {
                Button { showingDetail = true } label: {
                    pill.frame(minWidth: 44, minHeight: 44)
                }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .transition(notificationTransition)
            } else {
                pill.transition(notificationTransition)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: visualState)
        .accessibilityLabel(accessibilityLabel)
        .sheet(isPresented: $showingDetail) { detailSheet }
    }

    private var notificationTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985))
    }

    private var pill: some View {
        ChatCompactPillSurface(
            tone: presentation.tone,
            material: presentation.material,
            interactive: presentation.hasDetailSheet
        ) {
            ChatCompactPillLabel(
                icon: presentation.icon,
                title: presentation.title,
                detail: presentation.detail,
                tone: presentation.tone,
                showsProgress: presentation.showsProgress,
                titleWeight: .semibold,
                detailStyle: presentation.hasDetailSheet ? .summary : .status
            )
        }
    }

    private var accessibilityLabel: String {
        [presentation.title, presentation.detail].compactMap { $0 }.joined(separator: ", ")
    }

    private var visualState: ChatCompactPillVisualState {
        .init(
            id: presentation.id,
            title: presentation.title,
            detail: presentation.detail,
            icon: presentation.icon,
            tone: presentation.tone,
            material: presentation.material,
            showsProgress: presentation.showsProgress
        )
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                    if let body = presentation.body {
                        TronMarkdownView(text: body, streaming: false)
                            .padding(14)
                            .tronGlassSurface(accent: presentation.tone.surfaceColor, tintOpacity: 0.08)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: presentation.title, accent: presentation.tone.surfaceColor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showingDetail = false } label: {
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

struct TranscriptNotice: View {
    let title: String
    var value: String? = nil
    let icon: String
    let tone: ChatNotificationTone
    var animatesEntrance = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: Bool

    init(
        title: String,
        value: String? = nil,
        icon: String,
        tone: ChatNotificationTone,
        animatesEntrance: Bool = false
    ) {
        self.title = title
        self.value = value
        self.icon = icon
        self.tone = tone
        self.animatesEntrance = animatesEntrance
        _revealed = State(initialValue: !animatesEntrance)
    }

    var body: some View {
        ChatNotificationView(presentation: .init(
            id: "embedded-notice", semanticID: nil, icon: icon, title: title,
            detail: value, body: nil, tone: tone, material: .flat
        ))
        .opacity(revealed ? 1 : 0)
        .scaleEffect(revealed || reduceMotion ? 1 : 0.98)
        .offset(y: revealed || reduceMotion ? 0 : 3)
        .onAppear {
            guard animatesEntrance, !revealed else { return }
            if reduceMotion { revealed = true }
            else {
                withAnimation(.smooth(duration: 0.24)) { revealed = true }
            }
        }
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

struct ToolCard: View {
    let title: String
    let subtitle: String
    let content: String
    var error = false
    var request: JSONValue? = nil
    var response: JSONValue? = nil
    var fallbackContent: JSONValue? = nil
    var outputTruncated = false
    var timing: ChatToolPresentation? = nil
    var onOpenDetails: ((String) -> Void)? = nil
    @State private var detailPresentation: ToolDetailRoute?
    @State private var detailDetent: PresentationDetent = .medium
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        subtitle: String,
        content: String,
        error: Bool = false,
        request: JSONValue? = nil,
        response: JSONValue? = nil,
        fallbackContent: JSONValue? = nil,
        outputTruncated: Bool = false,
        timing: ChatToolPresentation? = nil,
        onOpenDetails: ((String) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.error = error
        self.request = request
        self.response = response
        self.fallbackContent = fallbackContent
        self.outputTruncated = outputTruncated
        self.timing = timing
        self.onOpenDetails = onOpenDetails
    }

    init(data: ChatToolPresentation, onOpenDetails: ((String) -> Void)? = nil) {
        self.init(
            title: data.title,
            subtitle: data.subtitle,
            content: data.content,
            error: data.error,
            request: data.request,
            response: data.response,
            fallbackContent: data.fallbackContent,
            outputTruncated: data.outputTruncated,
            timing: data,
            onOpenDetails: onOpenDetails
        )
    }

    var body: some View {
        Button {
            if let onOpenDetails {
                onOpenDetails(detailTool.id)
            } else {
                detailDetent = .medium
                detailPresentation = ToolDetailRoute(toolID: detailTool.id)
            }
        } label: {
            ChatCompactPillSurface(tone: tone, material: .glass, interactive: true) {
                ChatCompactPillLabel(
                    icon: icon,
                    title: displayTitle,
                    detail: subtitle.lowercased(),
                    tone: tone,
                    showsProgress: subtitle == "Running"
                ) {
                    if let timing {
                        ToolElapsedText(tool: timing, color: tone.secondaryColor)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: visualState)
        .toolDetailSheet(
            route: $detailPresentation,
            detent: $detailDetent,
            tool: detailPresentation?.resolve(in: [detailTool])
        )
    }

    private var detailTool: ChatToolPresentation {
        ChatToolPresentation(
            id: timing?.id ?? "",
            title: title,
            subtitle: subtitle,
            request: request,
            response: response,
            content: content,
            fallbackContent: fallbackContent,
            error: error,
            startedAt: timing?.startedAt,
            completedAt: timing?.completedAt,
            durationMs: timing?.durationMs,
            lastProgressAt: timing?.lastProgressAt,
            progressSequence: timing?.progressSequence,
            outputTruncated: timing?.outputTruncated ?? outputTruncated
        )
    }

    private var accessibilityLabel: String {
        let duration = timing?.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))
        return [displayTitle, subtitle, duration].compactMap { $0 }.joined(separator: ", ")
    }
    private var visualState: ChatCompactPillVisualState {
        .init(
            id: timing?.id ?? title,
            title: displayTitle,
            detail: subtitle.lowercased(),
            icon: icon,
            tone: tone,
            material: .glass,
            showsProgress: subtitle == "Running",
            durationMilliseconds: timing?.isRunning == false ? timing?.durationMs : nil
        )
    }
    private var tone: ChatNotificationTone {
        if error { return .error }
        return subtitle == "Running" ? .warning : .accent
    }
    private var displayTitle: String { ToolDetailPresentation.displayTitle(for: title) }
    private var icon: String {
        error ? "exclamationmark.triangle.fill" : ToolDetailPresentation.icon(for: title)
    }
}

struct ToolRunView: View {
    let run: ChatToolRunPresentation
    @State private var detailRoute: ToolDetailRoute?
    @State private var detailDetent: PresentationDetent = .medium
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if let tool = run.tools.first, run.tools.count == 1 {
                ToolCard(data: tool) { toolID in
                    detailDetent = .medium
                    detailRoute = ToolDetailRoute(toolID: toolID)
                }
                .transition(toolRunTransition)
            } else {
                ToolRunChip(run: run)
                    .transition(toolRunTransition)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: run.tools.count == 1)
        .toolDetailSheet(
            route: $detailRoute,
            detent: $detailDetent,
            tool: detailRoute?.resolve(in: run.tools)
        )
    }

    private var toolRunTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985, anchor: .leading))
    }
}

private struct ToolRunChip: View {
    let run: ChatToolRunPresentation
    @State private var showingDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tone: ChatNotificationTone {
        if run.failureCount > 0 { return .error }
        return run.isRunning ? .warning : .accent
    }
    private var surfaceAccent: Color { tone.surfaceColor }

    var body: some View {
        Button { showingDetails = true } label: {
            ChatCompactPillSurface(tone: tone, material: .glass, interactive: true) {
                ChatCompactPillLabel(
                    icon: run.failureCount > 0
                        ? "exclamationmark.triangle.fill" : "square.stack.3d.up",
                    title: run.title,
                    detail: run.status,
                    tone: tone,
                    showsProgress: run.isRunning
                ) {
                    ToolRunElapsedText(run: run, color: tone.secondaryColor)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: visualState)
        .accessibilityLabel(runAccessibilityLabel)
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(run.tools) { tool in
                            ToolCard(data: tool)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .tronScrollEdgeChrome()
                .tronToolDetailNavigationChrome()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TronSheetTitle(title: run.title, accent: surfaceAccent)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { showingDetails = false } label: {
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
            .tronPresentation()
        }
    }

    private var runAccessibilityLabel: String {
        let duration = run.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))
        return [run.title, run.status, duration].compactMap { $0 }.joined(separator: ", ")
    }

    private var visualState: ChatCompactPillVisualState {
        .init(
            id: run.id,
            title: run.title,
            detail: run.status,
            icon: run.failureCount > 0
                ? "exclamationmark.triangle.fill" : "square.stack.3d.up",
            tone: tone,
            material: .glass,
            showsProgress: run.isRunning,
            count: run.tools.count,
            durationMilliseconds: run.isRunning
                ? nil : run.tools.compactMap(\.durationMs).max()
        )
    }
}

private struct ToolElapsedText: View {
    let tool: ChatToolPresentation
    let color: Color

    var body: some View {
        if tool.isRunning {
            TimelineView(.periodic(from: ToolTiming.date(tool.startedAt) ?? .now, by: 0.5)) { context in
                elapsed(at: context.date)
            }
        } else {
            elapsed(at: .now)
        }
    }

    @ViewBuilder private func elapsed(at date: Date) -> some View {
        if let milliseconds = tool.elapsedMilliseconds(at: date) {
            Text(ToolTiming.format(milliseconds: milliseconds))
                .font(TronFont.mono(10, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct ToolRunElapsedText: View {
    let run: ChatToolRunPresentation
    let color: Color

    var body: some View {
        if run.isRunning {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in elapsed(at: context.date) }
        } else {
            elapsed(at: .now)
        }
    }

    @ViewBuilder private func elapsed(at date: Date) -> some View {
        if let milliseconds = run.elapsedMilliseconds(at: date) {
            Text(ToolTiming.format(milliseconds: milliseconds))
                .font(TronFont.mono(10, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct ToolDetailRoute: Identifiable, Hashable {
    let toolID: String
    var id: String { toolID }

    func resolve(in tools: [ChatToolPresentation]) -> ChatToolPresentation? {
        tools.first { $0.id == toolID }
    }
}

private struct ToolDetailSheetHost: ViewModifier {
    @Binding var route: ToolDetailRoute?
    @Binding var detent: PresentationDetent
    let tool: ChatToolPresentation?

    func body(content: Content) -> some View {
        content.sheet(item: $route) { _ in
            if let tool {
                let accent: Color = tool.error ? .tronError : .tronEmerald
                NavigationStack {
                    ToolDetailSheet(
                        tool: tool,
                        density: detent == .large ? .expanded : .glance
                    )
                    .tronToolDetailNavigationChrome()
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            TronSheetTitle(
                                title: ToolDetailPresentation.displayTitle(for: tool.title),
                                accent: accent
                            )
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button { route = nil } label: {
                                Image(systemName: "checkmark")
                                    .font(TronTypography.buttonSM)
                                    .foregroundStyle(Color.tronEmerald)
                            }
                            .accessibilityLabel("Done")
                        }
                    }
                }
                .tronTopBlur(.sheet)
                .presentationDetents([.medium, .large], selection: $detent)
                .presentationDragIndicator(.hidden)
                .tronPresentation()
            }
        }
    }
}

private extension View {
    func toolDetailSheet(
        route: Binding<ToolDetailRoute?>,
        detent: Binding<PresentationDetent>,
        tool: ChatToolPresentation?
    ) -> some View {
        modifier(ToolDetailSheetHost(route: route, detent: detent, tool: tool))
    }
}

private struct TranscriptImageChip: View {
    private struct LoadKey: Hashable {
        let identity: ChatMediaIdentity?
        let attempt: Int
    }

    private struct PreviewRequest: Hashable {
        let identity: ChatMediaIdentity
        let leaseID: UUID
    }

    @Environment(AppModel.self) private var model
    let blobID: String
    @State private var thumbnail: UIImage?
    @State private var thumbnailIdentity: ChatMediaIdentity?
    @State private var previewImage: UIImage?
    @State private var previewRequest: PreviewRequest?
    @State private var showPreview = false
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
                previewRequest = PreviewRequest(identity: identity, leaseID: UUID())
                showPreview = true
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
            showPreview = false
        }
        .accessibilityHint(currentThumbnail == nil ? "Loads the unavailable image again" : "Opens a photo preview")
        .sheet(isPresented: $showPreview) {
            if let previewImage, let previewRequest {
                AttachmentImagePreviewSheet(image: previewImage)
                    .task(id: previewRequest) {
                        guard let full = try? await model.chatMedia.fullPreview(
                            for: previewRequest.identity,
                            leaseID: previewRequest.leaseID
                        ), !Task.isCancelled,
                           showPreview,
                           self.identity == previewRequest.identity else { return }
                        self.previewImage = full
                    }
                    .onDisappear {
                        model.chatMedia.cancelFullPreview(
                            for: previewRequest.identity,
                            leaseID: previewRequest.leaseID
                        )
                        self.previewImage = nil
                        self.previewRequest = nil
                    }
            }
        }
    }
}

private struct TranscriptFileChip: View {
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
