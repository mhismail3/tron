import Observation
import SwiftUI
import UIKit

struct TronMarkdownView: View {
    let document: MarkdownPresentation.Document
    let streaming: Bool
    var textStyle = ChatSelectableTextStyle()
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
                if let annotation, Self.isSelectableProse(block.kind) {
                    if let range = selectableProseRange(startingAt: index) {
                        let blockKey = annotation.source.blockKey("prose:\(range.lowerBound):\(range.upperBound)")
                        ChatSelectableInlineText(
                            messageBlocks: Array(document.blocks[range]),
                            style: textStyle,
                            highlights: annotation.presenter.highlights(itemID: annotation.source.itemID, blockKey: blockKey),
                            revealSource: (annotation.presenter, annotation.source.itemID, blockKey),
                            onAnnotate: Self.annotate(blockKey: blockKey, annotation: annotation)
                        )
                        .chatRevealedSource(annotation.presenter, itemID: annotation.source.itemID, blockKey: blockKey)
                        .frame(alignment: .topLeading)
                    }
                } else {
                    switch block.kind {
                case .paragraph(let value):
                    if selectableText {
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
                    ) {
                        if let annotation {
                            annotatable(
                                MarkdownPresentation.Inline(source: value, attributedString: nil),
                                identity: "block:\(index)",
                                style: ChatSelectableTextStyle(size: 13, color: textStyle.color, mono: true, lineSpacing: 3),
                                annotation: annotation
                            )
                        } else {
                            Text(value).font(TronFont.mono(13)).lineSpacing(3).textSelection(.enabled)
                        }
                    }
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
                case .image(let alt, let destination):
                    MarkdownResourceImage(alt: alt, destination: destination)
                        .id(block.id)
                case .table(let rows):
                    MarkdownTable(rows: rows) { row, column, value in
                        let weight: Font.Weight = row == 0 ? .semibold : .regular
                        if let annotation {
                            annotatable(
                                value,
                                identity: "block:\(index):cell:\(row):\(column)",
                                style: ChatSelectableTextStyle(size: 12, weight: TronFontLoader.weight(weight), color: textStyle.color),
                                annotation: annotation
                            )
                            .fixedSize()
                        } else {
                            (value.attributedString.map { Text($0) } ?? Text(value.source))
                                .font(TronFont.body(12, weight: weight))
                        }
                    }
                case .rule:
                    Divider()
                    }
                }
            }
        }
        .font(TronFontLoader.createFont(size: textStyle.size, weight: textStyle.weight))
        .foregroundStyle(textStyle.color)
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

    private var annotation: (source: ChatAnnotationSource, presenter: ChatAnnotationPresenter)? {
        guard !streaming, let annotationSource, let annotationPresenter, annotationPresenter.admitsAnnotations else { return nil }
        return (annotationSource, annotationPresenter)
    }

    @ViewBuilder
    private func inlineBlock(
        _ value: MarkdownPresentation.Inline,
        identity: String,
        style: ChatSelectableTextStyle? = nil
    ) -> some View {
        let style = style ?? textStyle
        if let annotation {
            annotatable(value, identity: identity, style: style, annotation: annotation)
                .alignmentGuide(.firstTextBaseline) { _ in
                    ChatSelectableTextLayout.firstBaseline(style: style, sizeCategory: sizeCategory)
                }
        } else if !streaming, selectableText {
            ChatSelectableInlineText(inline: value, style: style, detectsLinks: true, onAnnotate: nil)
                .alignmentGuide(.firstTextBaseline) { _ in
                    ChatSelectableTextLayout.firstBaseline(style: style, sizeCategory: sizeCategory)
                }
        } else {
            streamingInline(value, identity: identity)
        }
    }

    private func annotatable(
        _ value: MarkdownPresentation.Inline,
        identity: String,
        style: ChatSelectableTextStyle,
        annotation: (source: ChatAnnotationSource, presenter: ChatAnnotationPresenter)
    ) -> some View {
        let (source, presenter) = annotation
        let blockKey = source.blockKey(identity)
        return ChatSelectableInlineText(
            inline: value,
            style: style,
            highlights: presenter.highlights(itemID: source.itemID, blockKey: blockKey),
            revealSource: (presenter, source.itemID, blockKey),
            onAnnotate: Self.annotate(blockKey: blockKey, annotation: annotation)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.accessibilitySource)
        .accessibilityAddTraits(.isStaticText)
        .chatRevealedSource(presenter, itemID: source.itemID, blockKey: blockKey)
    }

    private static func annotate(
        blockKey: String,
        annotation: (source: ChatAnnotationSource, presenter: ChatAnnotationPresenter)
    ) -> (String, NSRange, CGRect) -> Void {
        { quote, range, rect in
            annotation.presenter.begin(ChatAnnotationRequest(
                quote: quote,
                anchor: ChatAnnotationAnchor(
                    itemID: annotation.source.itemID,
                    blockKey: blockKey,
                    location: range.location,
                    length: range.length
                ),
                selectionRect: rect
            ))
        }
    }

    @ViewBuilder
    private func streamingInline(
        _ value: MarkdownPresentation.Inline,
        identity: String
    ) -> some View {
        ChatStreamingInlineText(
            inline: value,
            identity: identity,
            baseColor: textStyle.color,
            streaming: streaming
        )
    }

}

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

private struct CodeBlock<Content: View>: View {
    let language: String?
    let code: String
    let streaming: Bool
    @ViewBuilder let content: Content
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
                    TronHaptics.shared.play(.copied)
                    copyFeedback.markCopied()
                } label: {
                    Label(copyFeedback.copied ? "Copied" : "Copy", systemImage: copyFeedback.copied ? "checkmark" : "doc.on.doc")
                        .font(TronFont.body(10, weight: .medium))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .padding(12).fixedSize(horizontal: true, vertical: false)
                    .chatSecondaryScrollContent()
            }
        }
        .background(Color.tronSurfaceElevated, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.tronBorder, lineWidth: 0.5))
        .task(id: copyFeedback.generation) {
            let taskGeneration = copyFeedback.generation
            guard taskGeneration != 0 else { return }
            _ = await copyFeedback.resetIfCurrent(taskGeneration)
        }
        .onAppear { copyFeedback.appear() }
        .onDisappear { copyFeedback.disappear() }
    }
}

private struct MarkdownTable<Cell: View>: View {
    let rows: [[MarkdownPresentation.Inline]]
    @ViewBuilder let cell: (Int, Int, MarkdownPresentation.Inline) -> Cell
    private var widths: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<widths, id: \.self) { column in
                            Group {
                                if column < row.count { cell(rowIndex, column, row[column]) } else { Text("") }
                            }
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
