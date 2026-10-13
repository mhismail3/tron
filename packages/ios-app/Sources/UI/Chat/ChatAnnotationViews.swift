import SwiftUI

/// Shared annotation presentation: one accent, icon and title rule for the
/// staged composer chip, the sent-message chip and the detail sheet.
enum ChatAnnotationPresentation {
    static let icon = "text.quote"
    static let tone: ChatNotificationTone = .warning
    static let kindTitle = "Annotation"
    static let maximumTitleLength = 28

    @MainActor static var accent: Color { tone.surfaceColor }

    static func title(for annotation: ChatAnnotation) -> String {
        let flattened = annotation.quote
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > maximumTitleLength else { return "“\(flattened)”" }
        return "“\(flattened.prefix(maximumTitleLength).trimmingCharacters(in: .whitespaces))…”"
    }
}

/// A staged annotation above the composer input: the shared staged chip,
/// opening the editable annotation sheet.
struct ComposerAnnotationChip: View {
    let annotation: ChatAnnotation
    let onSave: (String) -> Void
    let onRemove: () -> Void
    @State private var showsDetail = false

    var body: some View {
        let title = ChatAnnotationPresentation.title(for: annotation)
        ComposerStagedChip(
            icon: ChatAnnotationPresentation.icon,
            title: title,
            tone: ChatAnnotationPresentation.tone,
            accent: ChatAnnotationPresentation.accent,
            openLabel: "Show annotation, \(title)",
            removeLabel: "Remove annotation, \(title)",
            onOpen: { showsDetail = true },
            onRemove: onRemove
        ) {
            EmptyView()
        }
        .tronManagedSheet(
            isPresented: $showsDetail,
            identity: "composer.annotation.\(annotation.id)"
        ) {
            ChatAnnotationSheet(annotation: annotation, editing: .init(onSave: onSave, onDelete: onRemove))
        }
    }
}

/// A sent annotation in the user message, presented like the canonical
/// resource chip and opening the same sheet read-only.
struct ChatSentAnnotationChip: View, Equatable {
    let annotation: ChatAnnotation
    @State private var showsDetail = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.annotation == rhs.annotation }

    var body: some View {
        let title = ChatAnnotationPresentation.title(for: annotation)
        ChatCompactPillSurface(
            tone: ChatAnnotationPresentation.tone,
            material: .glass,
            interactive: true,
            accentOverride: ChatAnnotationPresentation.accent,
            cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius
        ) {
            ChatCompactPillLabel(
                icon: ChatAnnotationPresentation.icon,
                title: title,
                detail: ChatAnnotationPresentation.kindTitle,
                tone: ChatAnnotationPresentation.tone,
                iconSize: ChatCompactPillLayoutPolicy.toolIconSize,
                titleWeight: .bold
            )
        }
        .chatCompactPillInteraction(
            accessibilityLabel: "Show annotation, \(title)",
            accessibilityValue: ChatAnnotationPresentation.kindTitle
        ) {
            showsDetail = true
        }
        .tronManagedSheet(isPresented: $showsDetail, identity: "chat.sent-annotation") {
            ChatAnnotationSheet(annotation: annotation, editing: nil)
        }
    }
}

/// Typed prompt text with any sent annotations recovered from its envelope:
/// annotation chips above the ordinary user bubble.
struct ChatUserPromptContent: View {
    let text: String

    var body: some View {
        let parsed = ChatAnnotationEnvelope.parse(text)
        let body = parsed?.body ?? text
        VStack(alignment: .trailing, spacing: 4) {
            if let parsed {
                ChatSentAnnotationChips(annotations: parsed.annotations)
            }
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserPromptText(text: body)
                    .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                    .padding(.top, ChatPromptContainerStyle.topPadding)
                    .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                    .modifier(UserPromptGlassModifier())
                    .modifier(ChatMessageCopyMenu(text: body))
            }
        }
    }
}

struct ChatSentAnnotationChips: View {
    let annotations: [ChatAnnotation]

    var body: some View {
        // Trailing-aligned like the canonical resource chip; several wrap to
        // a horizontally scrolling row that keeps the newest at the edge.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(annotations) { ChatSentAnnotationChip(annotation: $0) }
            }
            .chatSecondaryScrollContent()
        }
        .scrollClipDisabled()
        .defaultScrollAnchor(.trailing)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotations")
    }
}

/// Quote and comment for one annotation. Staged annotations are editable and
/// deletable; sent ones are read-only.
struct ChatAnnotationSheet: View {
    struct Editing {
        let onSave: (String) -> Void
        let onDelete: () -> Void
    }

    let annotation: ChatAnnotation
    let editing: Editing?
    @Environment(\.dismiss) private var dismiss
    @State private var comment: String

    init(annotation: ChatAnnotation, editing: Editing?) {
        self.annotation = annotation
        self.editing = editing
        _comment = State(initialValue: annotation.comment)
    }

    private var accent: Color { ChatAnnotationPresentation.accent }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Quote")
                        ChatQuoteBlock(rule: accent) {
                            Text(annotation.quote)
                                .font(TronFont.body())
                                .foregroundStyle(Color.tronTextSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("chat.annotation.quote")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Comment")
                        if editing != nil {
                            TextEditor(text: $comment)
                                .frame(minHeight: 120)
                                .tronTextEditor()
                                .accessibilityLabel("Annotation comment")
                        } else {
                            Text(annotation.comment.isEmpty ? "No comment" : annotation.comment)
                                .font(TronTypography.bodySM)
                                .foregroundStyle(annotation.comment.isEmpty ? Color.tronTextMuted : Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chat.annotation.comment")
                        }
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let editing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            editing.onDelete()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(Color.tronError)
                        }
                        .accessibilityLabel("Delete annotation")
                    }
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: ChatAnnotationPresentation.kindTitle, accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        editing?.onSave(comment.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel(editing == nil ? "Done" : "Save annotation")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accent)
        .tronSettingsVisualTheme(accent: accent)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.sheetSectionHeader)
            .foregroundStyle(Color.tronTextPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The floating comment bubble, anchored above the selection that is being
/// annotated and kept above the keyboard. It uses the composer input's glass
/// and controls so it reads as a small composer for one quote.
struct ChatAnnotationBubbleHost: View {
    let presenter: ChatAnnotationPresenter
    @State private var comment = ""
    @State private var bubbleHeight: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let margin: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            if let request = presenter.pending {
                let frame = proxy.frame(in: .global)
                let width = min(proxy.size.width - Self.margin * 2, 360)
                let anchorTop = request.selectionRect.minY - frame.minY
                let y = ChatAnnotationBubbleLayout.top(
                    anchorTop: anchorTop,
                    bubbleHeight: bubbleHeight,
                    containerHeight: proxy.size.height,
                    margin: Self.margin
                )
                bubble(request)
                    .frame(width: width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bubbleHeight = $0 }
                    .offset(x: (proxy.size.width - width) / 2, y: y)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                    .id(request.id)
            }
        }
        .animation(ChatMotion.composerSurfaceResize(reduceMotion: reduceMotion), value: presenter.pending?.id)
        .onChange(of: presenter.pending?.id) { _, id in
            comment = ""
            focused = id != nil
        }
    }

    private func bubble(_ request: ChatAnnotationRequest) -> some View {
        let accent = ChatAnnotationPresentation.accent
        return VStack(alignment: .leading, spacing: 8) {
            ChatQuoteBlock(rule: accent) {
                Text(request.quote)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat.annotation.bubble.quote")
            HStack(alignment: .bottom, spacing: 4) {
                TextField("Add a comment", text: $comment, axis: .vertical)
                    .font(TronFont.body())
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.done)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Annotation comment")
                Button { presenter.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: ComposerControlMetrics.symbolSize, weight: .semibold))
                        .foregroundStyle(Color.tronTextMuted)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel annotation")
                Button { presenter.save(comment: comment) } label: {
                    Image(systemName: "checkmark")
                        .font(TronTypography.sans(size: ComposerControlMetrics.symbolSize, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save annotation")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.annotation.bubble")
    }
}

enum ChatAnnotationBubbleLayout {
    /// Above the selection when it fits; otherwise pinned inside the visible
    /// region (which already excludes the keyboard and composer).
    static func top(anchorTop: CGFloat, bubbleHeight: CGFloat, containerHeight: CGFloat, margin: CGFloat) -> CGFloat {
        let preferred = anchorTop - bubbleHeight - margin
        let maximum = max(margin, containerHeight - bubbleHeight - margin)
        return min(max(preferred, margin), maximum)
    }
}
