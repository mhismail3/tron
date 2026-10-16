import Observation
import SwiftUI
import UIKit

struct TronMarkdownView: View {
    let document: MarkdownPresentation.Document
    let streaming: Bool
    /// Body typography for paragraphs and list items; headings keep their
    /// scale and take the color. The default is the transcript's.
    var textStyle = ChatSelectableTextStyle()
    /// Completed inline text uses native range selection with Copy and
    /// detected links even without annotation. Ask Question opts in so agents'
    /// URLs, commands and IDs can be copied; other surfaces keep SwiftUI text.
    var selectableText = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatAnnotationSource) private var annotationSource
    @Environment(\.chatAnnotationPresenter) private var annotationPresenter

    init(
        document: MarkdownPresentation.Document,
        streaming: Bool,
        textStyle: ChatSelectableTextStyle = ChatSelectableTextStyle(),
        selectableText: Bool = false
    ) {
        self.document = document
        self.streaming = streaming
        self.textStyle = textStyle
        self.selectableText = selectableText
    }

    init(
        text: String,
        streaming: Bool,
        textStyle: ChatSelectableTextStyle = ChatSelectableTextStyle(),
        selectableText: Bool = false
    ) {
        self.init(
            document: MarkdownPresentation.Document(source: text),
            streaming: streaming,
            textStyle: textStyle,
            selectableText: selectableText
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                // During a live stream, block positions are the stable
                // presentation slots while the authoritative source grows in
                // place. Completed code blocks add their content identity below
                // so copy state still resets when a block is replaced.
                if !streaming, let annotationSource, let annotationPresenter, annotationPresenter.admitsAnnotations,
                   Self.isSelectableProse(block.kind) {
                    if let range = selectableProseRange(startingAt: index) {
                        let blocks = Array(document.blocks[range])
                        let blockKey = annotationSource.blockKey("prose:\(range.lowerBound):\(range.upperBound)")
                        ChatSelectableInlineText(
                            messageBlocks: blocks,
                            style: textStyle,
                            highlights: annotationPresenter.highlights(
                                itemID: annotationSource.itemID,
                                blockKey: blockKey
                            ),
                            isSelectable: !dynamicTypeSize.isAccessibilitySize,
                            onAnnotate: { quote, selectedRange, rect in
                                annotationPresenter.begin(ChatAnnotationRequest(
                                    quote: quote,
                                    anchor: ChatAnnotationAnchor(
                                        itemID: annotationSource.itemID,
                                        blockKey: blockKey,
                                        location: selectedRange.location,
                                        length: selectedRange.length
                                    ),
                                    selectionRect: rect
                                ))
                            }
                        )
                        .frame(alignment: .topLeading)
                    }
                } else {
                    switch block.kind {
                case .paragraph(let value):
                    if selectableText {
                        // The native text view stays the element so its
                        // links remain activatable by VoiceOver and tests.
                        inlineBlock(value, identity: "block:\(index)")
                            .frame(alignment: .topLeading)
                    } else {
                        inlineBlock(value, identity: "block:\(index)")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(value.accessibilitySource)
                            .accessibilityAddTraits(.isStaticText)
                            .accessibilityRespondsToUserInteraction(false)
                            .frame(alignment: .topLeading)
                    }
                case .heading(let level, let value):
                    let size = max(14, 22 - CGFloat(level * 2))
                    let weight: Font.Weight = level <= 2 ? .bold : .semibold
                    inlineBlock(
                        value,
                        identity: "block:\(index)",
                        style: ChatSelectableTextStyle(
                            size: size,
                            weight: TronFontLoader.weight(weight),
                            color: textStyle.color
                        )
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
                            style: ChatSelectableTextStyle(size: textStyle.size, weight: textStyle.weight, color: .tronTextSecondary)
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
        }
        .font(TronFontLoader.createFont(size: textStyle.size, weight: textStyle.weight))
        .foregroundStyle(textStyle.color)
        // A transcript row is one lazy child even when this eager block stack
        // contains hundreds of paragraphs. Always publish the exact wrapped
        // vertical ideal instead of accepting a viewport-sized/stale proposal;
        // otherwise LazyVStack can retain an invalid estimate after a live
        // assistant row settles and place later rows against phantom geometry.
        .fixedSize(horizontal: false, vertical: true)
        .transcriptTextSelection(enabled: !dynamicTypeSize.isAccessibilitySize)
    }

    private func selectableProseRange(startingAt index: Int) -> Range<Int>? {
        guard index == 0 || !Self.isSelectableProse(document.blocks[index - 1].kind) else { return nil }
        var end = index + 1
        while end < document.blocks.count, Self.isSelectableProse(document.blocks[end].kind) { end += 1 }
        return index..<end
    }

    private static func isSelectableProse(_ kind: MarkdownPresentation.Block.Kind) -> Bool {
        switch kind {
        case .paragraph, .heading, .list: true
        default: false
        }
    }

    /// A completed assistant block in the transcript is natively selectable
    /// and annotatable; streaming text and every other Markdown surface keep
    /// the SwiftUI reveal renderer.
    @ViewBuilder
    private func inlineBlock(
        _ value: MarkdownPresentation.Inline,
        identity: String,
        style: ChatSelectableTextStyle? = nil
    ) -> some View {
        let style = style ?? textStyle
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
        } else if !streaming, selectableText {
            ChatSelectableInlineText(inline: value, style: style, detectsLinks: true, onAnnotate: nil)
                .alignmentGuide(.firstTextBaseline) { _ in
                    ChatSelectableTextLayout.firstBaseline(style: style, sizeCategory: sizeCategory)
                }
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
            baseColor: textStyle.color,
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
