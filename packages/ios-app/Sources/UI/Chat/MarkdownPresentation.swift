import Foundation

/// A pure, immutable Markdown presentation namespace. `Document` is the sole cold
/// parser result consumed by the chat renderer.
enum MarkdownPresentation: Sendable {
    struct Document: Hashable, Sendable {
        let source: String
        let blocks: [Block]

        init(source: String) {
            self.source = source
            blocks = ColdParser.parse(source)
        }

        var accountedByteCount: Int {
            source.utf8.count + blocks.reduce(0) { $0 + $1.accountedByteCount }
        }
    }

    struct SourceRange: Hashable, Sendable {
        /// UTF-8 byte offsets in the exact `Document.source` supplied to the parser.
        let lowerBound: Int
        let upperBound: Int
    }

    /// SwiftUI subtree state survives only for an exact unchanged source slice.
    /// Content or type-changing revisions receive a new identity so interaction
    /// state such as code-copy confirmation cannot transfer to another block.
    struct SourceIdentity: Hashable, Sendable {
        let sourceRange: SourceRange
        let content: String
    }

    struct Inline: Hashable, Sendable {
        let source: String
        let attributedString: AttributedString?

        var accessibilitySource: String { source }

        init(source: String) {
            self.init(
                source: source,
                attributedString: try? AttributedString(
                    markdown: source,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )
            )
        }

        init(source: String, attributedString: AttributedString?) {
            self.source = source
            self.attributedString = attributedString
        }

        var accountedByteCount: Int {
            // Source storage plus a conservative source-sized presentation charge
            // for the attributed value's characters and runs.
            source.utf8.count * 2
        }
    }

    struct Block: Identifiable, Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case paragraph(Inline)
            case heading(level: Int, inline: Inline)
            case code(language: String?, code: String)
            case quote(Inline)
            case list([ListItem])
            case table([[String]])
            case rule

            var accountedByteCount: Int {
                switch self {
                case .paragraph(let inline), .quote(let inline):
                    inline.accountedByteCount
                case .heading(_, let inline):
                    inline.accountedByteCount
                case .code(let language, let code):
                    (language?.utf8.count ?? 0) + code.utf8.count
                case .list(let items):
                    items.reduce(0) { $0 + $1.accountedByteCount }
                case .table(let rows):
                    rows.reduce(0) { total, row in
                        total + row.reduce(0) { $0 + $1.utf8.count }
                    }
                case .rule:
                    0
                }
            }
        }

        let id: SourceIdentity
        let sourceRange: SourceRange
        let kind: Kind
        let isOpenCodeFence: Bool

        var accountedByteCount: Int {
            id.content.utf8.count + kind.accountedByteCount
        }
    }

    struct ListItem: Identifiable, Hashable, Sendable {
        let id: SourceIdentity
        let sourceRange: SourceRange
        let depth: Int
        let marker: String
        let inline: Inline

        var accountedByteCount: Int {
            id.content.utf8.count + marker.utf8.count + inline.accountedByteCount
        }
    }

    private struct SourceLine {
        let text: String
        let range: SourceRange
    }

    private enum ColdParser {
        static func parse(_ source: String) -> [Block] {
            let lines = sourceLines(source)
            var result: [Block] = []
            var index = 0

            while index < lines.count {
                let line = lines[index].text
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    index += 1
                    continue
                }
                if trimmed.hasPrefix("```") {
                    let start = index
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    index += 1
                    var code: [String] = []
                    while index < lines.count,
                          !lines[index].text.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        code.append(lines[index].text)
                        index += 1
                    }
                    let isOpenCodeFence = index == lines.count
                    if !isOpenCodeFence { index += 1 }
                    append(
                        .code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")),
                        lines: lines,
                        start: start,
                        end: index,
                        source: source,
                        isOpenCodeFence: isOpenCodeFence,
                        to: &result
                    )
                    continue
                }
                if let heading = heading(trimmed) {
                    append(
                        .heading(level: heading.0, inline: Inline(source: heading.1)),
                        lines: lines,
                        start: index,
                        end: index + 1,
                        source: source,
                        to: &result
                    )
                    index += 1
                    continue
                }
                if isRule(trimmed) {
                    append(.rule, lines: lines, start: index, end: index + 1, source: source, to: &result)
                    index += 1
                    continue
                }
                if trimmed.hasPrefix(">") {
                    let start = index
                    var values: [String] = []
                    while index < lines.count,
                          lines[index].text.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                        values.append(
                            String(lines[index].text.trimmingCharacters(in: .whitespaces).dropFirst())
                                .trimmingCharacters(in: .whitespaces)
                        )
                        index += 1
                    }
                    append(
                        .quote(Inline(source: values.joined(separator: "\n"))),
                        lines: lines,
                        start: start,
                        end: index,
                        source: source,
                        to: &result
                    )
                    continue
                }
                if let first = listItem(lines[index], source: source) {
                    let start = index
                    var items = [first]
                    index += 1
                    while index < lines.count, let item = listItem(lines[index], source: source) {
                        items.append(item)
                        index += 1
                    }
                    append(
                        .list(items),
                        lines: lines,
                        start: start,
                        end: index,
                        source: source,
                        to: &result
                    )
                    continue
                }
                if index + 1 < lines.count, line.contains("|"), isTableSeparator(lines[index + 1].text) {
                    let start = index
                    var rows: [[String]] = [cells(line)]
                    index += 2
                    while index < lines.count, lines[index].text.contains("|") {
                        rows.append(cells(lines[index].text))
                        index += 1
                    }
                    append(
                        .table(rows),
                        lines: lines,
                        start: start,
                        end: index,
                        source: source,
                        to: &result
                    )
                    continue
                }

                let start = index
                var paragraph = [line]
                index += 1
                while index < lines.count {
                    let next = lines[index].text
                    let value = next.trimmingCharacters(in: .whitespaces)
                    if value.isEmpty || value.hasPrefix("```") || heading(value) != nil
                        || value.hasPrefix(">") || listItemComponents(next) != nil
                        || isRule(value) {
                        break
                    }
                    paragraph.append(next)
                    index += 1
                }
                append(
                    .paragraph(Inline(source: paragraph.joined(separator: "\n"))),
                    lines: lines,
                    start: start,
                    end: index,
                    source: source,
                    to: &result
                )
            }
            return result
        }

        private static func sourceLines(_ source: String) -> [SourceLine] {
            let values = source.components(separatedBy: "\n")
            var offset = 0
            return values.enumerated().map { index, text in
                let end = offset + text.utf8.count
                defer { offset = end + (index + 1 < values.count ? 1 : 0) }
                return SourceLine(text: text, range: .init(lowerBound: offset, upperBound: end))
            }
        }

        private static func append(
            _ kind: Block.Kind,
            lines: [SourceLine],
            start: Int,
            end: Int,
            source: String,
            isOpenCodeFence: Bool = false,
            to result: inout [Block]
        ) {
            let range = SourceRange(
                lowerBound: lines[start].range.lowerBound,
                upperBound: lines[end - 1].range.upperBound
            )
            result.append(Block(
                id: identity(range: range, source: source),
                sourceRange: range,
                kind: kind,
                isOpenCodeFence: isOpenCodeFence
            ))
        }

        private static func identity(range: SourceRange, source: String) -> SourceIdentity {
            let utf8 = source.utf8
            let lower = utf8.index(utf8.startIndex, offsetBy: range.lowerBound)
            let upper = utf8.index(utf8.startIndex, offsetBy: range.upperBound)
            return SourceIdentity(sourceRange: range, content: String(decoding: utf8[lower..<upper], as: UTF8.self))
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

        private static func listItem(_ line: SourceLine, source: String) -> ListItem? {
            guard let value = listItemComponents(line.text) else { return nil }
            return ListItem(
                id: identity(range: line.range, source: source),
                sourceRange: line.range,
                depth: value.depth,
                marker: value.marker,
                inline: Inline(source: value.text)
            )
        }

        private static func listItemComponents(_ line: String) -> (depth: Int, marker: String, text: String)? {
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
            let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            let value = line.dropFirst(leading.count)
            if value.hasPrefix("- ") || value.hasPrefix("* ") || value.hasPrefix("+ ") {
                return (depth, "•", String(value.dropFirst(2)))
            }
            if let dot = value.firstIndex(of: "."),
               Int(value[..<dot]) != nil,
               value.index(after: dot) < value.endIndex,
               value[value.index(after: dot)] == " " {
                return (depth, String(value[...dot]), String(value[value.index(dot, offsetBy: 2)...]))
            }
            return nil
        }

        private static func isTableSeparator(_ line: String) -> Bool {
            let values = cells(line)
            return !values.isEmpty && values.allSatisfy {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "-: ")).isEmpty && $0.contains("-")
            }
        }

        private static func cells(_ line: String) -> [String] {
            var value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }
            if value.hasSuffix("|") { value.removeLast() }
            return value.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}
