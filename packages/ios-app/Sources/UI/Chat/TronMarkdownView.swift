import Observation
import SwiftUI
import UIKit

struct TronMarkdownView: View {
    let document: MarkdownPresentation.Document
    let streaming: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatAnnotationSource) private var annotationSource
    @Environment(\.chatAnnotationPresenter) private var annotationPresenter

    init(document: MarkdownPresentation.Document, streaming: Bool) {
        self.document = document
        self.streaming = streaming
    }

    init(text: String, streaming: Bool) {
        self.init(document: MarkdownPresentation.Document(source: text), streaming: streaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                // During a live stream, block positions are the stable
                // presentation slots while the authoritative source grows in
                // place. Completed code blocks add their content identity below
                // so copy state still resets when a block is replaced.
                switch block.kind {
                case .paragraph(let value):
                    inlineBlock(value, identity: "block:\(index)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(value.accessibilitySource)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityRespondsToUserInteraction(false)
                        .frame(alignment: .topLeading)
                case .heading(let level, let value):
                    let size = max(14, 22 - CGFloat(level * 2))
                    let weight: Font.Weight = level <= 2 ? .bold : .semibold
                    inlineBlock(
                        value,
                        identity: "block:\(index)",
                        style: ChatSelectableTextStyle(size: size, weight: TronFontLoader.weight(weight))
                    )
                    .font(TronFont.body(size, weight: weight))
                    .padding(.top, level <= 2 ? 6 : 2)
                case .code(let language, let value):
                    CodeBlock(
                        language: language,
                        code: value,
                        streaming: streaming && block.isOpenCodeFence
                    )
                    .id(block.id)
                case .quote(let value):
                    ChatQuoteBlock {
                        inlineBlock(
                            value,
                            identity: "block:\(index)",
                            style: ChatSelectableTextStyle(color: .tronTextSecondary)
                        )
                        .foregroundStyle(Color.tronTextSecondary)
                    }
                case .list(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.marker).frame(minWidth: 10, alignment: .leading)
                                inlineBlock(item.inline, identity: "block:\(index):item:\(itemIndex)")
                            }.padding(.leading, CGFloat(item.depth) * 14)
                        }
                    }
                case .table(let rows):
                    MarkdownTable(rows: rows)
                case .rule:
                    Divider()
                }
            }
        }
        .font(TronFont.body())
        .foregroundStyle(Color.assistantMessageText)
        // A transcript row is one lazy child even when this eager block stack
        // contains hundreds of paragraphs. Always publish the exact wrapped
        // vertical ideal instead of accepting a viewport-sized/stale proposal;
        // otherwise LazyVStack can retain an invalid estimate after a live
        // assistant row settles and place later rows against phantom geometry.
        .fixedSize(horizontal: false, vertical: true)
        .transcriptTextSelection(enabled: !dynamicTypeSize.isAccessibilitySize)
    }

    /// A completed assistant block in the transcript is natively selectable
    /// and annotatable; streaming text and every other Markdown surface keep
    /// the SwiftUI reveal renderer.
    @ViewBuilder
    private func inlineBlock(
        _ value: MarkdownPresentation.Inline,
        identity: String,
        style: ChatSelectableTextStyle = ChatSelectableTextStyle()
    ) -> some View {
        if !streaming, let annotationSource, let annotationPresenter, annotationPresenter.admitsAnnotations {
            let blockKey = annotationSource.blockKey(identity)
            ChatSelectableInlineText(
                inline: value,
                style: style,
                highlights: annotationPresenter.highlights(itemID: annotationSource.itemID, blockKey: blockKey),
                onAnnotate: { quote, range, rect in
                    annotationPresenter.begin(ChatAnnotationRequest(
                        quote: quote,
                        anchor: ChatAnnotationAnchor(
                            itemID: annotationSource.itemID,
                            blockKey: blockKey,
                            location: range.location,
                            length: range.length
                        ),
                        selectionRect: rect
                    ))
                }
            )
            .alignmentGuide(.firstTextBaseline) { _ in
                ChatSelectableTextLayout.firstBaseline(style: style, sizeCategory: sizeCategory)
            }
            // Assistive technologies read it as the static text it replaces.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.accessibilitySource)
            .accessibilityAddTraits(.isStaticText)
        } else {
            streamingInline(value, identity: identity)
        }
    }

    @ViewBuilder
    private func streamingInline(
        _ value: MarkdownPresentation.Inline,
        identity: String
    ) -> some View {
        // Keep one mounted view type as the response crosses the streaming
        // boundary. Changing from a reveal view to a fresh Text at completion
        // recreates the whole final paragraph and produces the visible flash.
        ChatStreamingInlineText(
            inline: value,
            identity: identity,
            baseColor: Color.assistantMessageText,
            streaming: streaming
        )
    }

}

/// The Markdown blockquote treatment: a rule beside secondary text. Quoted
/// annotations reuse it so a quote reads the same everywhere in chat.
struct ChatQuoteBlock<Content: View>: View {
    var rule: Color = .tronBorder
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(rule).frame(width: 3)
            content
        }
    }
}

extension View {
    @ViewBuilder
    func transcriptTextSelection(enabled: Bool) -> some View {
        if enabled { self.textSelection(.enabled) }
        else { self }
    }
}

@MainActor
@Observable
final class CodeCopyFeedbackLifecycle {
    private(set) var copied = false
    private(set) var generation = 0
    private var mounted = true
    private let sleep: @Sendable (Duration) async throws -> Void

    init() {
        sleep = { duration in try await Task.sleep(for: duration) }
    }

    #if HOSTED_TEST
    init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.sleep = sleep
    }
    #endif

    func markCopied() {
        copied = true
        generation &+= 1
    }

    func appear() {
        // SwiftUI can retain this owner across disappearance. Retirement has
        // already advanced the generation, so old resets remain inadmissible.
        mounted = true
    }

    func disappear() {
        mounted = false
        generation &+= 1
        copied = false
    }

    @discardableResult
    func resetIfCurrent(_ taskGeneration: Int) async -> Bool {
        do {
            try await sleep(.seconds(1.2))
            guard !Task.isCancelled, mounted, generation == taskGeneration else { return false }
            copied = false
            return true
        } catch {
            return false
        }
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    let streaming: Bool
    @State private var copyFeedback = CodeCopyFeedbackLifecycle()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(TronFont.body(10, weight: .medium)).foregroundStyle(Color.tronTextMuted)
                Spacer()
                if streaming { TronPulseLoadingIndicator(accent: .tronEmerald, size: 16) }
                Button {
                    UIPasteboard.general.string = code
                    copyFeedback.markCopied()
                } label: {
                    Label(copyFeedback.copied ? "Copied" : "Copy", systemImage: copyFeedback.copied ? "checkmark" : "doc.on.doc")
                        .font(TronFont.body(10, weight: .medium))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(TronFont.mono(13)).lineSpacing(3).textSelection(.enabled)
                    .padding(12).fixedSize(horizontal: true, vertical: false)
                    .chatSecondaryScrollContent()
            }
        }
        .background(Color.tronSurfaceElevated, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.tronBorder, lineWidth: 0.5))
        .task(id: copyFeedback.generation) {
            let taskGeneration = copyFeedback.generation
            guard taskGeneration != 0 else { return }
            // The lifecycle owner keeps the delay, cancellation, generation,
            // and mount fence in one shipping path for every configuration.
            _ = await copyFeedback.resetIfCurrent(taskGeneration)
        }
        .onAppear { copyFeedback.appear() }
        .onDisappear { copyFeedback.disappear() }
    }
}

private struct MarkdownTable: View {
    let rows: [[MarkdownPresentation.Inline]]
    private var widths: Int { rows.map(\.count).max() ?? 0 }

    private func cell(_ value: MarkdownPresentation.Inline?) -> Text {
        guard let value else { return Text("") }
        if let attributed = value.attributedString { return Text(attributed) }
        return Text(value.source)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<widths, id: \.self) { column in
                            cell(column < row.count ? row[column] : nil)
                                .font(TronFont.body(12, weight: rowIndex == 0 ? .semibold : .regular))
                                .padding(.vertical, 2)
                        }
                    }
                    if rowIndex == 0 { Divider().gridCellColumns(widths) }
                }
            }.padding(10)
                .chatSecondaryScrollContent()
        }
        .background(Color.tronSurfaceElevated, in: RoundedRectangle(cornerRadius: 9))
    }
}
