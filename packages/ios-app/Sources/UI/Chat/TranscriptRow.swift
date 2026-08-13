import SwiftUI

struct TranscriptRow: View, Equatable {
    let item: TranscriptItem
    var streaming = false
    var toolResults: [String: TranscriptItem] = [:]
    var rendersToolCalls = true
    var projectedMessageParts: [ChatMessagePart]? = nil
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
                    request: .object(["command": .string(item.command ?? "")])
                )
            case .customMessage:
                ToolCard(
                    title: item.customType ?? "Extension",
                    subtitle: "Extension message",
                    content: item.text.isEmpty ? item.details?.prettyPrinted ?? "" : item.text,
                    response: item.details
                )
            case .customEntry:
                ToolCard(
                    title: item.customType ?? "Extension state",
                    subtitle: "Extension state",
                    content: item.customData?.prettyPrinted ?? "",
                    response: item.customData
                )
            case .compaction:
                SummaryNotice(
                    icon: "arrow.down.right.and.arrow.up.left",
                    title: "Context compacted",
                    text: item.summary ?? "",
                    detail: item.tokensBefore.map(ChatTokenCountPresentation.beforeCompaction)
                )
            case .branchSummary:
                SummaryNotice(icon: "arrow.triangle.branch", title: "Branch summary", text: item.summary ?? "", detail: nil)
            case .modelChange:
                TranscriptNotice(
                    title: "Model changed",
                    value: item.modelRef.map { "\($0.provider) / \($0.id)" } ?? "Changed",
                    icon: "cpu",
                    tint: .tronEmerald
                )
            case .thinkingChange:
                TranscriptNotice(
                    title: "Thinking changed",
                    value: item.level?.capitalized ?? "Changed",
                    icon: "brain",
                    tint: .tronEmerald
                )
            case .label:
                TranscriptNotice(
                    title: item.label.map { "Bookmark: \($0)" } ?? "Bookmark removed",
                    icon: "bookmark",
                    tint: .tronSlate
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
    }

    @ViewBuilder private var message: some View {
        if item.role == .toolResult {
            ToolCard(
                title: item.toolName ?? "Tool result",
                subtitle: item.isError == true ? "Failed" : "Completed",
                content: item.text.isEmpty ? item.details?.prettyPrinted ?? "" : item.text,
                error: item.isError == true,
                response: item.details
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
                            label: hiddenThinkingLabel,
                            animatesInsertion: streaming
                        )
                    case .content(let part):
                        switch part.type {
                        case .text:
                            if part.attachment != nil {
                                EmptyView() // Presented together above the prompt text.
                            } else if item.role == .user {
                                Text(part.text ?? "").font(TronTypography.body).foregroundStyle(Color.userMessageText)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.trailing)
                                    .frame(minHeight: 44, alignment: .topTrailing)
                            } else {
                                MarkdownText(text: part.text ?? "", streaming: streaming)
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
                                        content: result.text.isEmpty ? result.details?.prettyPrinted ?? "" : result.text,
                                        error: result.isError == true,
                                        request: part.arguments,
                                        response: result.details
                                    )
                                } else {
                                    ToolCard(
                                        title: part.name ?? "Tool",
                                        subtitle: "Invocation",
                                        content: part.arguments?.prettyPrinted ?? "",
                                        request: part.arguments
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
                        tint: .tronError
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
                maxWidth: item.role == .user ? 520 : .infinity,
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

/// Shared compact visual treatment for transcript navigation and summary pills.
/// The glass remains content-sized while the owning button supplies a separate
/// 44-point semantic target.
struct ChatTranscriptPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(Color.tronAccentText)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.16)).interactive(), in: Capsule())
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
/// This deliberately covers configuration changes, errors, bookmarks, and
/// extension status notices so small one-off labels cannot regress readability.
struct TranscriptNotice: View {
    let title: String
    var value: String? = nil
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let value {
                Text(value)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }
}

private struct ThinkingBlock: View {
    let segments: [ChatThinkingSegment]
    let label: String?
    let animatesInsertion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleSegmentIDs: Set<String>

    init(segments: [ChatThinkingSegment], label: String?, animatesInsertion: Bool) {
        self.segments = segments
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
            return paragraph + separator + rendered(segment.text)
                .foregroundColor(Color.tronTextSecondary.opacity(segmentOpacity(segment.id)))
        }
    }

    private func rendered(_ value: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return Text(value) }
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
    let streaming: Bool
    var body: some View { TronMarkdownView(text: text, streaming: streaming) }
}

struct ToolCard: View {
    let title: String
    let subtitle: String
    let content: String
    var error = false
    var request: JSONValue? = nil
    var response: JSONValue? = nil
    var timing: ChatToolPresentation? = nil
    @State private var detailPresentation: ToolDetailPresentation?

    init(
        title: String,
        subtitle: String,
        content: String,
        error: Bool = false,
        request: JSONValue? = nil,
        response: JSONValue? = nil,
        timing: ChatToolPresentation? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.error = error
        self.request = request
        self.response = response
        self.timing = timing
    }

    init(data: ChatToolPresentation) {
        self.init(
            title: data.title,
            subtitle: data.subtitle,
            content: data.content,
            error: data.error,
            request: data.request,
            response: data.response,
            timing: data
        )
    }

    var body: some View {
        Button { detailPresentation = ToolDetailPresentation() } label: {
            HStack(spacing: 7) {
                if subtitle == "Running" {
                    ProgressView().controlSize(.small).tint(accent).frame(width: 18, height: 18)
                } else {
                    Image(systemName: icon).font(TronFont.body(10, weight: .semibold)).foregroundStyle(accent).frame(width: 18, height: 18)
                }
                Text(displayTitle).font(TronFont.body(12, weight: .bold)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
                Text(subtitle.lowercased()).font(TronFont.mono(10, weight: .semibold)).foregroundStyle(accent.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                if let timing {
                    ToolElapsedText(tool: timing, color: accent.opacity(0.72))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .glassEffect(
                .regular.tint(surfaceAccent.opacity(0.26)).interactive(),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
        .contentTransition(.opacity)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: subtitle)
        .sheet(item: $detailPresentation) { _ in
            NavigationStack {
                ScrollView {
                    toolDetailContent
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .tronScrollEdgeChrome()
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .principal) { TronSheetTitle(title: displayTitle, accent: accent) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { detailPresentation = nil } label: {
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

    private var toolDetailContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(accent)
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                if subtitle == "Running" { ProgressView().controlSize(.small).tint(accent) }
                Spacer()
                if let timing {
                    ToolElapsedText(tool: timing, color: Color.tronTextSecondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .tronGlassSurface(accent: accent, tintOpacity: 0.08)
            if let timing, timing.isRunning {
                ToolActivityAgeText(tool: timing, color: Color.tronTextMuted)
            }
            if let request { toolPayloadBlock("Request", value: request) }
            if !content.isEmpty, content != response?.prettyPrinted {
                textPayloadSection
            }
            if let response {
                toolPayloadBlock(subtitle == "Running" ? "Current result" : "Response", value: response)
            } else if content.isEmpty, request == nil {
                TronSettingsGroup("Details", accent: accent) {
                    TronSettingsRow(
                        icon: icon,
                        title: "No additional details",
                        subtitle: "The tool completed without displayable output.",
                        accent: accent
                    )
                }
            }
        }
    }

    private func toolPayloadBlock(_ title: String, value: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(Color.tronTextMuted)
            TronStructuredJSONView(value: value, title: title, accent: accent)
        }
    }

    private var textPayloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subtitle == "Running" ? "LIVE OUTPUT" : displayTitle == "Run command" ? "RESPONSE" : "DETAILS")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(Color.tronTextMuted)
            if displayTitle == "Run command" {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(content)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(Color.tronTextSecondary)
                        .textSelection(.enabled)
                        .padding(14)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .tronGlassSurface(accent: accent, tintOpacity: 0.08)
            } else {
                TronMarkdownView(text: content, streaming: subtitle == "Running")
                    .padding(14)
                    .tronGlassSurface(accent: accent, tintOpacity: 0.08)
            }
        }
    }

    private var accessibilityLabel: String {
        let duration = timing?.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))
        return [displayTitle, subtitle, duration].compactMap { $0 }.joined(separator: ", ")
    }
    private var accent: Color { error ? .tronError : .tronAccentText }
    private var surfaceAccent: Color { error ? .tronError : subtitle == "Running" ? .tronAmber : .tronEmerald }
    private var displayTitle: String {
        switch title.lowercased() {
        case "read": "Read file"
        case "write": "Write file"
        case "edit": "Edit file"
        case "bash": "Run command"
        case "grep": "Search text"
        case "find": "Find files"
        case "ls": "List files"
        default: title
        }
    }
    private var icon: String {
        if error { return "exclamationmark.triangle.fill" }
        return switch title.lowercased() {
        case "read": "doc.text"
        case "write": "square.and.pencil"
        case "edit": "pencil.and.outline"
        case "bash": "terminal"
        case "grep": "text.magnifyingglass"
        case "find": "doc.text.magnifyingglass"
        case "ls": "folder"
        default: "wrench.and.screwdriver"
        }
    }
}

struct ToolRunView: View {
    let run: ChatToolRunPresentation

    @ViewBuilder var body: some View {
        if let tool = run.tools.first, run.tools.count == 1 {
            ToolCard(data: tool)
        } else {
            ToolRunChip(run: run)
        }
    }
}

private struct ToolRunChip: View {
    let run: ChatToolRunPresentation
    @State private var showingDetails = false

    private var accent: Color { run.failureCount > 0 ? .tronError : .tronAccentText }
    private var surfaceAccent: Color { run.failureCount > 0 ? .tronError : .tronEmerald }

    var body: some View {
        Button { showingDetails = true } label: {
            HStack(spacing: 7) {
                if run.isRunning {
                    ProgressView().controlSize(.small).tint(accent).frame(width: 18, height: 18)
                } else {
                    Image(systemName: run.failureCount > 0 ? "exclamationmark.triangle.fill" : "square.stack.3d.up")
                        .font(TronFont.body(10, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 18, height: 18)
                }
                Text(run.title)
                    .font(TronFont.body(12, weight: .bold))
                    .foregroundStyle(accent)
                if let status = run.status {
                    Text(status)
                        .font(TronFont.mono(10, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.74))
                }
                ToolRunElapsedText(run: run, color: accent.opacity(0.74))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .glassEffect(
                .regular.tint(surfaceAccent.opacity(0.26)).interactive(),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
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
                .navigationTitle("")
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
                .frame(minWidth: 48, alignment: .trailing)
        }
    }
}

private struct ToolActivityAgeText: View {
    let tool: ChatToolPresentation
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let update = ToolTiming.date(tool.lastProgressAt),
               let start = ToolTiming.date(tool.startedAt) {
                let age = max(0, Int(context.date.timeIntervalSince(update)))
                let label = update <= start && age > 1
                    ? "No additional runtime output yet · \(ageLabel(age))"
                    : "Last runtime update \(ageLabel(age))"
                Text(label)
                    .font(TronFont.mono(10, weight: .medium))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(label)
            }
        }
    }

    private func ageLabel(_ seconds: Int) -> String {
        if seconds < 2 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m \(seconds % 60)s ago"
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
                .frame(minWidth: 48, alignment: .trailing)
        }
    }
}

private struct ToolDetailPresentation: Identifiable {
    let id = UUID()
}

private struct SummaryNotice: View {
    let icon, title, text: String
    let detail: String?
    @State private var showingDetail = false

    var body: some View {
        Button { showingDetail = true } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
                if let detail {
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(1)
                }
            }
            .chatTranscriptPill()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)\(detail.map { ", \($0)" } ?? "")")
        .sheet(isPresented: $showingDetail) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let detail {
                            Text(detail)
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                        TronMarkdownView(text: text, streaming: false)
                            .padding(14)
                            .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.08)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top)
                .tronScrollEdgeChrome()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { TronSheetTitle(title: title) }
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
}

private struct TranscriptImageChip: View {
    @Environment(AppModel.self) private var model
    let blobID: String
    @State private var image: UIImage?
    @State private var showPreview = false
    @State private var loadFailed = false
    @State private var loadAttempt = 0

    var body: some View {
        Button {
            if image != nil { showPreview = true }
            else if loadFailed { loadAttempt &+= 1 }
        } label: {
            Group {
                if let image {
                    Image(uiImage: image)
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
        .task(id: loadAttempt) {
            guard image == nil else { return }
            loadFailed = false
            guard let value = try? await model.client.blob(id: blobID),
                  let loaded = UIImage(data: value.0) else {
                loadFailed = true
                return
            }
            image = loaded
        }
        .accessibilityHint(image == nil ? "Loads the unavailable image again" : "Opens a photo preview")
        .sheet(isPresented: $showPreview) {
            if let image {
                AttachmentImagePreviewSheet(image: image)
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
