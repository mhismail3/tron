import SwiftUI
import UIKit

struct TronMarkdownView: View {
    let text: String
    let streaming: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var blocks: [Block] { Parser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                switch block.kind {
                case .paragraph(let value):
                    inline(value)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(value)
                        .accessibilityRespondsToUserInteraction(false)
                        .frame(alignment: .topLeading)
                case .heading(let level, let value):
                    inline(value)
                        .font(TronFont.body(max(14, 22 - CGFloat(level * 2)), weight: level <= 2 ? .bold : .semibold))
                        .padding(.top, level <= 2 ? 6 : 2)
                case .code(let language, let value): CodeBlock(language: language, code: value, streaming: streaming)
                case .quote(let value):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.tronBorder).frame(width: 3)
                        inline(value).foregroundStyle(Color.tronTextSecondary)
                    }
                case .list(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.marker).frame(minWidth: 10, alignment: .leading)
                                inline(item.text)
                            }.padding(.leading, CGFloat(item.depth) * 14)
                        }
                    }
                case .table(let rows): MarkdownTable(rows: rows)
                case .rule: Divider()
                }
            }
        }
        .font(TronFont.body())
        .foregroundStyle(Color.assistantMessageText)
        .transcriptTextSelection(enabled: !dynamicTypeSize.isAccessibilitySize)
    }

    private func inline(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(value)
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

private struct Block: Identifiable {
    enum Kind { case paragraph(String), heading(Int, String), code(String?, String), quote(String), list([ListItem]), table([[String]]), rule }
    let id: Int
    let kind: Kind
}

private struct ListItem: Identifiable {
    let id: Int
    let depth: Int
    let marker: String
    let text: String
}

private enum Parser {
    static func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                result.append(.init(id: result.count, kind: .code(language.isEmpty ? nil : language, code.joined(separator: "\n"))))
                continue
            }
            if let heading = heading(trimmed) {
                result.append(.init(id: result.count, kind: .heading(heading.0, heading.1))); index += 1; continue
            }
            if isRule(trimmed) { result.append(.init(id: result.count, kind: .rule)); index += 1; continue }
            if trimmed.hasPrefix(">") {
                var values: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    values.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); index += 1
                }
                result.append(.init(id: result.count, kind: .quote(values.joined(separator: "\n")))); continue
            }
            if let first = listItem(line, id: 0) {
                var items = [first]; index += 1
                while index < lines.count, let item = listItem(lines[index], id: items.count) { items.append(item); index += 1 }
                result.append(.init(id: result.count, kind: .list(items))); continue
            }
            if index + 1 < lines.count, line.contains("|"), isTableSeparator(lines[index + 1]) {
                var rows: [[String]] = [cells(line)]
                index += 2
                while index < lines.count, lines[index].contains("|") { rows.append(cells(lines[index])); index += 1 }
                result.append(.init(id: result.count, kind: .table(rows))); continue
            }
            var paragraph = [line]; index += 1
            while index < lines.count {
                let next = lines[index]
                let value = next.trimmingCharacters(in: .whitespaces)
                if value.isEmpty || value.hasPrefix("```") || heading(value) != nil || value.hasPrefix(">") || listItem(next, id: 0) != nil || isRule(value) { break }
                paragraph.append(next); index += 1
            }
            result.append(.init(id: result.count, kind: .paragraph(paragraph.joined(separator: "\n"))))
        }
        return result
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return (count, String(line.dropFirst(count + 1)))
    }
    private static func isRule(_ line: String) -> Bool {
        let value = line.replacingOccurrences(of: " ", with: "")
        return value.count >= 3 && Set(value).count == 1 && "-*_".contains(value.first!)
    }
    private static func listItem(_ line: String, id: Int) -> ListItem? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let value = line.dropFirst(leading.count)
        if value.hasPrefix("- ") || value.hasPrefix("* ") || value.hasPrefix("+ ") {
            return .init(id: id, depth: depth, marker: "•", text: String(value.dropFirst(2)))
        }
        if let dot = value.firstIndex(of: "."), Int(value[..<dot]) != nil, value.index(after: dot) < value.endIndex, value[value.index(after: dot)] == " " {
            return .init(id: id, depth: depth, marker: String(value[...dot]), text: String(value[value.index(dot, offsetBy: 2)...]))
        }
        return nil
    }
    private static func isTableSeparator(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-: ")).isEmpty && $0.contains("-") }
    }
    private static func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
