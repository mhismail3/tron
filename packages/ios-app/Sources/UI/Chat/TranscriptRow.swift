import SwiftUI

struct TranscriptRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    var streaming = false
    var toolResults: [String: TranscriptItem] = [:]
    var rendersToolCalls = true

    var body: some View {
        VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 8) {
            switch item.kind {
            case .message:
                message
            case .bash:
                ToolCard(title: item.command ?? "Shell", subtitle: item.cancelled == true ? "Cancelled" : "Exit \(item.exitCode.map(String.init) ?? "—")", content: item.output ?? "")
            case .customMessage:
                ToolCard(
                    title: item.customType ?? "Extension",
                    subtitle: "Extension message",
                    content: item.text.isEmpty ? item.details?.prettyPrinted ?? "" : item.text,
                    structured: item.details
                )
            case .customEntry:
                ToolCard(
                    title: item.customType ?? "Extension state",
                    subtitle: "Extension state",
                    content: item.customData?.prettyPrinted ?? "",
                    structured: item.customData
                )
            case .compaction:
                SummaryCard(icon: "arrow.down.right.and.arrow.up.left", title: "Context compacted", text: item.summary ?? "", detail: item.tokensBefore.map { "\($0) tokens before compaction" })
            case .branchSummary:
                SummaryCard(icon: "arrow.triangle.branch", title: "Branch summary", text: item.summary ?? "", detail: nil)
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
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
    }

    @ViewBuilder private var message: some View {
        if item.role == .toolResult {
            ToolCard(
                title: item.toolName ?? "Tool result",
                subtitle: item.isError == true ? "Failed" : "Completed",
                content: item.text.isEmpty ? item.details?.prettyPrinted ?? "" : item.text,
                error: item.isError == true,
                structured: item.details
            )
        } else {
            VStack(alignment: item.role == .user ? .trailing : .leading, spacing: 8) {
                ForEach(item.content ?? []) { part in
                    switch part.type {
                    case .text:
                        if item.role == .user {
                            Text(part.text ?? "").font(TronTypography.body).foregroundStyle(Color.userMessageText)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.trailing)
                                .frame(minHeight: 44, alignment: .topTrailing)
                        } else {
                            MarkdownText(text: part.text ?? "", streaming: streaming)
                        }
                    case .thinking:
                        ThinkingBlock(text: part.text ?? "", label: model.selectedSnapshot?.extensionUI.hiddenThinkingLabel)
                    case .image:
                        if let id = part.blobId { TranscriptAttachmentChip(blobID: id) }
                    case .toolCall:
                        if rendersToolCalls {
                            if let callID = part.toolCallId, let result = toolResults[callID] {
                                ToolCard(
                                    title: part.name ?? result.toolName ?? "Tool",
                                    subtitle: result.isError == true ? "Failed" : "Completed",
                                    content: result.text.isEmpty ? result.details?.prettyPrinted ?? "" : result.text,
                                    error: result.isError == true,
                                    structured: result.details
                                )
                            } else {
                                ToolCard(
                                    title: part.name ?? "Tool",
                                    subtitle: "Invocation",
                                    content: part.arguments?.prettyPrinted ?? "",
                                    structured: part.arguments
                                )
                            }
                        }
                    }
                }
                if let error = item.errorMessage, !error.isEmpty {
                    TranscriptNotice(
                        title: error,
                        icon: "exclamationmark.triangle.fill",
                        tint: .tronError
                    )
                }
                if item.role == .assistant,
                   item.content?.contains(where: { $0.type == .text && !($0.text ?? "").isEmpty }) == true,
                   let provider = item.provider,
                   let modelName = item.modelId {
                    Text("\(provider) / \(modelName)").font(TronFont.mono(10)).foregroundStyle(Color.tronTextSecondary)
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, item.role == .user ? 0 : 4)
            .frame(
                maxWidth: item.role == .user ? 520 : .infinity,
                minHeight: 44,
                alignment: item.role == .user ? .topTrailing : .topLeading
            )
        }
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
    let text: String
    let label: String?
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label, !label.isEmpty { Text(label).font(TronFont.body(11, weight: .semibold)).foregroundStyle(.secondary) }
            rendered(expanded ? normalized : preview)
                .font(TronFont.body(12)).foregroundStyle(Color.tronTextSecondary).italic()
                .lineLimit(expanded || dynamicTypeSize.isAccessibilitySize ? nil : 2).lineSpacing(1)
                .accessibilityLabel(normalized)
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { expanded.toggle() } }
    }

    private func rendered(_ value: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return Text(value) }
        return Text(attributed)
    }

    private var normalized: String {
        text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var preview: String { String(normalized.prefix(140)) }
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
    var structured: JSONValue? = nil
    @State private var detailPresentation: ToolDetailPresentation?

    init(
        title: String,
        subtitle: String,
        content: String,
        error: Bool = false,
        structured: JSONValue? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.error = error
        self.structured = structured
    }

    init(data: ChatToolPresentation) {
        self.init(
            title: data.title,
            subtitle: data.subtitle,
            content: data.content,
            error: data.error,
            structured: data.structured
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
                Text(subtitle.lowercased()).font(TronFont.mono(10, weight: .semibold)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
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
        .accessibilityLabel("\(displayTitle), \(subtitle)")
        .accessibilityValue(title)
        .contentTransition(.opacity)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: subtitle)
        .animation(.easeInOut(duration: 0.18), value: content)
        .sheet(item: $detailPresentation) { _ in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TronSettingsGroup("Outcome", accent: accent) {
                            TronSettingsRow(icon: icon, title: subtitle, accent: accent) {
                                if subtitle == "Running" { ProgressView().controlSize(.small).tint(accent) }
                            }
                        }

                        if let structured {
                            TronStructuredJSONView(value: structured, title: displayTitle, accent: accent)
                        } else if content.isEmpty {
                            TronSettingsGroup("Details", accent: accent) {
                                TronSettingsRow(
                                    icon: icon,
                                    title: "No additional details",
                                    subtitle: "The tool completed without displayable output.",
                                    accent: accent
                                )
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(displayTitle == "Run command" ? "OUTPUT" : "DETAILS")
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
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top)
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .tronPresentation()
        }
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
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .glassEffect(
                .regular.tint(surfaceAccent.opacity(0.26)).interactive(),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(run.title)\(run.status.map { ", \($0)" } ?? "")")
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(run.tools) { tool in
                            ToolCard(data: tool)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top)
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .tronPresentation()
        }
    }
}

private struct ToolDetailPresentation: Identifiable {
    let id = UUID()
}

private struct SummaryCard: View {
    let icon, title, text: String
    let detail: String?
    var body: some View {
        DisclosureGroup {
            Text(text).font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary).textSelection(.enabled).padding(.top, 8)
        } label: {
            Label(title, systemImage: icon).font(TronFont.body(13, weight: .semibold))
        }
        .padding(12).tronGlassSurface(accent: .tronSlate, cornerRadius: 14, tintOpacity: 0.10)
        .overlay(alignment: .bottomTrailing) { if let detail { Text(detail).font(TronTypography.caption2).foregroundStyle(Color.tronTextMuted).padding(8) } }
    }
}

private struct TranscriptAttachmentChip: View {
    @Environment(AppModel.self) private var model
    let blobID: String
    @State private var image: UIImage?
    @State private var showPreview = false

    var body: some View {
        Button { showPreview = true } label: {
            HStack(spacing: 7) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    ProgressView().controlSize(.mini).tint(.tronBlue).frame(width: 28, height: 28)
                }
                Text("Image attachment")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
                    .foregroundStyle(Color.tronTextPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronBlue.opacity(0.24)).interactive(), in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
        .task {
            guard image == nil,
                  let value = try? await model.client.blob(id: blobID),
                  let loaded = UIImage(data: value.0) else { return }
            image = loaded
        }
        .sheet(isPresented: $showPreview) {
            NavigationStack {
                Group {
                    if let image {
                        ZoomableAttachmentImage(image: image)
                    } else {
                        TronLoadingState(label: "Loading image…")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { TronSheetTitle(title: "Attachment", accent: .tronBlue) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { showPreview = false } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(Color.tronEmerald)
                        }
                        .accessibilityLabel("Done")
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .tint(Color.tronEmerald)
        }
    }
}

private struct ZoomableAttachmentImage: View {
    let image: UIImage
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(16)
        }
        .tronScrollEdgeChrome()
    }
}
