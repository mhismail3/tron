import SwiftUI
import UIKit

struct TronMarkdownView: View {
    let document: MarkdownPresentation.Document
    let streaming: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                    streamingInline(value, identity: "block:\(index)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(value.accessibilitySource)
                        .accessibilityRespondsToUserInteraction(false)
                        .frame(alignment: .topLeading)
                case .heading(let level, let value):
                    streamingInline(value, identity: "block:\(index)")
                        .font(TronFont.body(max(14, 22 - CGFloat(level * 2)), weight: level <= 2 ? .bold : .semibold))
                        .padding(.top, level <= 2 ? 6 : 2)
                case .code(let language, let value):
                    CodeBlock(
                        language: language,
                        code: value,
                        streaming: streaming && block.isOpenCodeFence
                    )
                    .id(block.id)
                case .quote(let value):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.tronBorder).frame(width: 3)
                        streamingInline(value, identity: "block:\(index)")
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                case .list(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.marker).frame(minWidth: 10, alignment: .leading)
                                streamingInline(item.inline, identity: "block:\(index):item:\(itemIndex)")
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

    private func inline(_ value: MarkdownPresentation.Inline) -> Text {
        if let attributed = value.attributedString {
            return Text(attributed)
        }
        return Text(value.source)
    }
}

extension View {
    @ViewBuilder
    func transcriptTextSelection(enabled: Bool) -> some View {
        if enabled { self.textSelection(.enabled) }
        else { self }
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    let streaming: Bool
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(TronFont.body(10, weight: .medium)).foregroundStyle(Color.tronTextMuted)
                Spacer()
                if streaming { ProgressView().controlSize(.mini).tint(.tronEmerald) }
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(TronFont.body(10, weight: .medium))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(TronFont.mono(13)).lineSpacing(3).textSelection(.enabled)
                    .padding(12).fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(Color.tronSurfaceElevated, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.tronBorder, lineWidth: 0.5))
    }
}

private struct MarkdownTable: View {
    let rows: [[String]]
    private var widths: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<widths, id: \.self) { column in
                            Text(column < row.count ? row[column] : "")
                                .font(TronFont.body(12, weight: rowIndex == 0 ? .semibold : .regular))
                                .padding(.vertical, 2)
                        }
                    }
                    if rowIndex == 0 { Divider().gridCellColumns(widths) }
                }
            }.padding(10)
        }
        .background(Color.tronSurfaceElevated, in: RoundedRectangle(cornerRadius: 9))
    }
}
