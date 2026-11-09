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
        .tronManagedSheet(isPresented: $showsDetail, instance: annotation.id, identity: "chat.sent-annotation") {
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
                PromptTextPreview(text: body)
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
        // Trailing-aligned like the canonical resource chip, one per line so
        // every quote stays readable beside the message it belongs to.
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(annotations) { ChatSentAnnotationChip(annotation: $0) }
        }
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
    @Environment(\.chatAnnotationPresenter) private var presenter
    @PresentationState private var comment: String
    /// Set by tapping the quote: the source is revealed once the sheet is gone.
    @State private var revealsSource = false

    init(annotation: ChatAnnotation, editing: Editing?) {
        self.annotation = annotation
        self.editing = editing
        _comment = PresentationState(wrappedValue: annotation.comment)
    }

    private var accent: Color { ChatAnnotationPresentation.accent }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                TronSettingsSections(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Quote")
                        ChatQuoteBlock(rule: accent) {
                            Text(annotation.quote)
                                .font(TronTypography.body)
                                .foregroundStyle(Color.tronTextSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("chat.annotation.quote")
                        .modifier(ChatAnnotationQuoteReveal(enabled: presenter != nil && annotation.anchor != nil) {
                            // Like Save: keep the edited comment, then show the source.
                            editing?.onSave(comment.trimmingCharacters(in: .whitespacesAndNewlines))
                            revealsSource = true
                            dismiss()
                        })
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Comment")
                        if editing != nil {
                            // Grows with the comment so the sheet, not an inner
                            // box, scrolls a long one.
                            TextField("Add a comment", text: $comment, axis: .vertical)
                                .font(TronTypography.body)
                                .foregroundStyle(Color.tronTextPrimary)
                                .accessibilityLabel("Annotation comment")
                        } else {
                            Text(annotation.comment.isEmpty ? "No comment" : annotation.comment)
                                .font(TronTypography.body)
                                .foregroundStyle(annotation.comment.isEmpty ? Color.tronTextMuted : Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("chat.annotation.comment")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                                .tronToolbarAction(role: .destructive)
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
                            .tronToolbarAction(accent: accent)
                    }
                    .accessibilityLabel(editing == nil ? "Done" : "Save annotation")
                }
            }
        }
        .onDisappear {
            if revealsSource { presenter?.reveal(annotation) }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accent)
        .tronSettingsVisualTheme(accent: accent)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .tronSectionHeading()
            .foregroundStyle(Color.tronTextPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A staged annotation's quote is a button that shows its source in the
/// transcript. A quote without a source anchor (a sent annotation) stays text.
private struct ChatAnnotationQuoteReveal: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows the quote in the chat")
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}

/// The floating comment bubble, anchored above the selection that is being
/// annotated and kept above the keyboard. It uses the composer input's glass
/// and controls so it reads as a small composer for one quote.
struct ChatAnnotationBubbleHost: View {
    let presenter: ChatAnnotationPresenter
    /// Saving continues in the composer: it takes the keyboard from the
    /// comment field before the bubble is removed, so it never drops.
    let composer: ChatComposerResponder
    @State private var comment = ""
    @State private var bubbleHeight: CGFloat = 0
    @State private var region: CGRect = .zero
    /// The region's bottom when Annotate was chosen. The transcript follows
    /// its bottom edge as the keyboard rises, so the selection moves by the
    /// same amount and the bubble follows it.
    @State private var capturedRegionMaxY: CGFloat?
    @State private var selection: TextSelection?
    /// The comment Shift+Return produced; its newline is an edit, not a save.
    @State private var lineBreakComment: String?
    /// A hardware Return also ends the vertical field's editing; after
    /// Shift+Return's line break the comment takes focus back once.
    @State private var refocusAfterLineBreak = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let margin: CGFloat = 12
    private static var returnSaves: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// `new` is `old` with exactly one newline typed into it.
    private static func isTypedNewline(from old: String, to new: String) -> Bool {
        guard new.count == old.count + 1 else { return false }
        let old = Array(old), new = Array(new)
        let index = zip(old, new).prefix { $0 == $1 }.count
        return new[index] == "\n" && Array(new[(index + 1)...]) == Array(old[index...])
    }

    var body: some View {
        GeometryReader { proxy in
            if let request = presenter.pending {
                let frame = proxy.frame(in: .global)
                let width = min(proxy.size.width - Self.margin * 2, 360)
                let shift = (capturedRegionMaxY ?? frame.maxY) - frame.maxY
                let anchorTop = request.selectionRect.minY - shift - frame.minY
                let y = ChatAnnotationBubbleLayout.top(
                    anchorTop: anchorTop,
                    bubbleHeight: bubbleHeight,
                    containerHeight: proxy.size.height,
                    margin: Self.margin
                )
                bubble(request)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bubbleHeight = $0 }
                    .offset(x: (proxy.size.width - width) / 2, y: y)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                    .id(request.id)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { region = $0 }
        .animation(ChatMotion.composerSurfaceResize(reduceMotion: reduceMotion), value: presenter.pending?.id)
        .onChange(of: presenter.pending?.id) { _, id in
            comment = ""
            selection = nil
            refocusAfterLineBreak = false
            capturedRegionMaxY = id == nil ? nil : region.maxY
            // Only claim focus. Clearing it on close would resign whichever
            // responder holds the keyboard by then, i.e. the composer after Save.
            if id != nil { focused = true }
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
                commentField
                    .font(TronFont.body())
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.done)
                    // iPad: Return saves like the check. A hardware Return would
                    // otherwise end editing, so Shift+Return inserts the multi-line
                    // comment's newline here. iPhone Return stays a newline.
                    .onKeyPress(.return, phases: .all) { press in
                        guard Self.returnSaves else { return .ignored }
                        // Consume the whole press; the field acts on more than key-down.
                        guard press.phase == .down else { return .handled }
                        if press.modifiers.contains(.shift) {
                            insertLineBreak()
                        } else {
                            save(comment)
                        }
                        return .handled
                    }
                    .onChange(of: focused) { _, isFocused in
                        guard refocusAfterLineBreak else { return }
                        refocusAfterLineBreak = false
                        if !isFocused { focused = true }
                    }
                    // The on-screen Return key arrives as one typed newline;
                    // dictation's "new line" stays text.
                    .onChange(of: comment) { old, new in
                        guard Self.returnSaves else { return }
                        defer { lineBreakComment = nil }
                        if new != lineBreakComment { refocusAfterLineBreak = false }
                        guard new != lineBreakComment, Self.isTypedNewline(from: old, to: new),
                              !ChatTextInputFocus.isDictating else { return }
                        comment = old
                        save(old)
                    }
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
                Button { save(comment) } label: {
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

    /// Only iPad edits at the selection (Shift+Return); iPhone keeps the
    /// field without a selection binding.
    @ViewBuilder private var commentField: some View {
        if Self.returnSaves {
            TextField("Add a comment", text: $comment, selection: $selection, axis: .vertical)
        } else {
            TextField("Add a comment", text: $comment, axis: .vertical)
        }
    }

    private func insertLineBreak() {
        let range: Range<String.Index> = switch selection?.indices {
        case .selection(let range)? where range.upperBound <= comment.endIndex: range
        default: comment.endIndex..<comment.endIndex
        }
        let offset = comment.distance(from: comment.startIndex, to: range.lowerBound)
        comment.replaceSubrange(range, with: "\n")
        lineBreakComment = comment
        selection = TextSelection(insertionPoint: comment.index(comment.startIndex, offsetBy: offset + 1))
        refocusAfterLineBreak = true
    }

    private func save(_ comment: String) {
        // UIKit moves the keyboard's input target directly from the
        // still-installed comment field, so it is never dismissed.
        _ = composer.becomeFirstResponder()
        presenter.save(comment: comment)
    }
}

/// The focused text input, read from the first responder that `sendAction`
/// reaches.
@MainActor
enum ChatTextInputFocus {
    fileprivate static weak var reported: UIResponder?

    static var firstResponder: UIResponder? {
        reported = nil
        UIApplication.shared.sendAction(#selector(UIResponder.tronReportFirstResponder), to: nil, from: nil, for: nil)
        defer { reported = nil }
        return reported
    }

    static var isDictating: Bool {
        firstResponder?.textInputMode?.primaryLanguage == "dictation"
    }

    /// Whether a text input other than `view` holds the keyboard (the composer
    /// or a comment field).
    static func keyboardIsOwned(byAnotherThan view: UIView) -> Bool {
        guard let responder = firstResponder, responder !== view else { return false }
        if let textView = responder as? UITextView { return textView.isEditable }
        if let field = responder as? UITextField { return field.isEnabled }
        return false
    }
}

private extension UIResponder {
    @objc func tronReportFirstResponder() { ChatTextInputFocus.reported = self }
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
