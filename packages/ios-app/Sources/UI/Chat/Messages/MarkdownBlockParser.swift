import Foundation

// MARK: - Markdown Block Types

struct MarkdownBlock: Equatable, Identifiable {
    /// Stable identity based on position and content hash for efficient SwiftUI diffing.
    let id: String
    let kind: Kind

    enum Kind: Equatable {
        case header(level: Int, content: String)
        case paragraph(content: String)
        case codeBlock(language: String?, code: String)
        case blockquote(content: String)
        case list(items: [MarkdownListItem])
        case table(MarkdownTable)
        case horizontalRule
    }

    init(index: Int, kind: Kind) {
        self.kind = kind
        // Combine position with a content fingerprint for stable identity.
        // Position alone breaks on insert; content alone breaks on duplicates.
        let contentHash: Int
        switch kind {
        case .header(_, let c), .paragraph(let c), .blockquote(let c):
            contentHash = c.hashValue
        case .codeBlock(let lang, let code):
            contentHash = (lang ?? "").hashValue &+ code.hashValue
        case .list(let items):
            contentHash = items.hashValue
        case .table(let t):
            contentHash = t.hashValue
        case .horizontalRule:
            contentHash = 0
        }
        self.id = "\(index)-\(contentHash)"
    }
}

struct MarkdownListItem: Equatable, Hashable {
    enum Marker: Equatable, Hashable {
        case unordered
        case ordered(Int)
    }

    let depth: Int
    let marker: Marker
    var content: String
}

private struct ParsedMarkdownListLine {
    let indentColumns: Int
    let marker: MarkdownListItem.Marker
    let content: String
}

// MARK: - Block-Level Markdown Parser

enum MarkdownBlockParser {
    /// Parse markdown text into block-level segments.
    /// Handles: headers, code fences, blockquotes, lists, tables, horizontal rules, paragraphs.
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line — skip (paragraph accumulation handles grouping)
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let language = extractCodeLanguage(trimmed)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                let code = codeLines.joined(separator: "\n")
                blocks.append(MarkdownBlock(index: blocks.count, kind: .codeBlock(language: language, code: code)))
                continue
            }

            // Horizontal rule (---, ***, ___ with optional spaces, at least 3 chars)
            if isHorizontalRule(trimmed) {
                blocks.append(MarkdownBlock(index: blocks.count, kind: .horizontalRule))
                i += 1
                continue
            }

            // Table — peek ahead for separator row
            if MarkdownTableParser.isTableLine(trimmed) {
                var tableLines: [String] = []
                while i < lines.count {
                    let tl = lines[i].trimmingCharacters(in: .whitespaces)
                    guard MarkdownTableParser.isTableLine(tl) else { break }
                    tableLines.append(tl)
                    i += 1
                }
                if let table = MarkdownTableParser.parseTable(tableLines) {
                    blocks.append(MarkdownBlock(index: blocks.count, kind: .table(table)))
                } else {
                    // Not a valid table — treat as paragraph
                    blocks.append(MarkdownBlock(index: blocks.count, kind: .paragraph(content: tableLines.joined(separator: "\n"))))
                }
                continue
            }

            // Header (# through ######)
            if let (level, content) = parseHeader(trimmed) {
                blocks.append(MarkdownBlock(index: blocks.count, kind: .header(level: level, content: content)))
                i += 1
                continue
            }

            // Blockquote (> prefix)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    guard ql.hasPrefix(">") else { break }
                    // Strip leading > and optional space
                    var stripped = String(ql.dropFirst())
                    if stripped.hasPrefix(" ") { stripped = String(stripped.dropFirst()) }
                    quoteLines.append(stripped)
                    i += 1
                }
                blocks.append(MarkdownBlock(index: blocks.count, kind: .blockquote(content: quoteLines.joined(separator: "\n"))))
                continue
            }

            // Preserve source indentation and marker type so nested and mixed
            // lists retain hierarchy instead of flattening into top-level rows.
            if parseListItem(line) != nil {
                var items: [MarkdownListItem] = []
                var indentationLevels: [Int] = []
                var lastItemIndentColumns = 0
                while i < lines.count {
                    let listLine = lines[i]
                    let listTrimmed = listLine.trimmingCharacters(in: .whitespaces)
                    if listTrimmed.isEmpty { break }
                    if let parsed = parseListLine(listLine) {
                        let depth = normalizedListDepth(
                            for: parsed.indentColumns,
                            indentationLevels: &indentationLevels
                        )
                        items.append(
                            MarkdownListItem(
                                depth: depth,
                                marker: parsed.marker,
                                content: parsed.content
                            )
                        )
                        lastItemIndentColumns = parsed.indentColumns
                    } else if !items.isEmpty,
                              leadingIndentColumns(in: listLine) > lastItemIndentColumns {
                        items[items.count - 1].content += " " + listTrimmed
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(MarkdownBlock(index: blocks.count, kind: .list(items: items)))
                continue
            }

            // Paragraph — accumulate consecutive non-empty, non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let pl = lines[i]
                let pt = pl.trimmingCharacters(in: .whitespaces)
                if pt.isEmpty { break }
                if pt.hasPrefix("```") || pt.hasPrefix("#") || pt.hasPrefix(">")
                    || parseListItem(pl) != nil
                    || isHorizontalRule(pt) || MarkdownTableParser.isTableLine(pt) { break }
                paraLines.append(pl)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(MarkdownBlock(index: blocks.count, kind: .paragraph(content: paraLines.joined(separator: "\n"))))
            }
        }

        return blocks.filter { block in
            switch block.kind {
            case .paragraph(let content):
                return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .blockquote(let content):
                return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .header(_, let content):
                return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .codeBlock(_, let code):
                return !code.isEmpty
            case .list(let items):
                return !items.isEmpty
            case .table, .horizontalRule:
                return true
            }
        }
    }

    // MARK: - Line Classification Helpers

    private static func extractCodeLanguage(_ fenceLine: String) -> String? {
        let stripped = fenceLine.trimmingCharacters(in: .whitespaces)
        let afterBackticks = stripped.drop(while: { $0 == "`" })
        let lang = afterBackticks.trimmingCharacters(in: .whitespaces)
        return lang.isEmpty ? nil : lang
    }

    private static func parseHeader(_ line: String) -> (level: Int, content: String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        guard line.count > level else { return (level, "") }
        let rest = line[line.index(line.startIndex, offsetBy: level)...]
        // Must have a space after the hashes (standard markdown)
        guard rest.hasPrefix(" ") else { return nil }
        let content = rest.trimmingCharacters(in: .whitespaces)
        return (level, content)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        let chars = Set(stripped)
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }

    private static func parseListItem(_ line: String) -> MarkdownListItem? {
        guard let parsed = parseListLine(line) else { return nil }
        return MarkdownListItem(
            depth: 0,
            marker: parsed.marker,
            content: parsed.content
        )
    }

    private static func parseListLine(_ line: String) -> ParsedMarkdownListLine? {
        let columns = leadingIndentColumns(in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
            return ParsedMarkdownListLine(
                indentColumns: columns,
                marker: .unordered,
                content: String(trimmed.dropFirst(2))
            )
        }

        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let prefix = trimmed[trimmed.startIndex..<dotIndex]
        guard let number = Int(prefix), !prefix.isEmpty else { return nil }
        let afterDot = trimmed.index(after: dotIndex)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        return ParsedMarkdownListLine(
            indentColumns: columns,
            marker: .ordered(number),
            content: String(trimmed[trimmed.index(after: afterDot)...])
        )
    }

    /// Normalize source indentation into semantic hierarchy levels.
    ///
    /// Models commonly emit either two spaces, four spaces, or a tab for one
    /// nested level. Distinct increasing indentation establishes one new level
    /// regardless of its raw width; returning to a prior width restores that
    /// level. This avoids visually doubling four-space Markdown indentation.
    private static func normalizedListDepth(
        for columns: Int,
        indentationLevels: inout [Int]
    ) -> Int {
        guard let current = indentationLevels.last else {
            indentationLevels = [columns]
            return 0
        }

        if columns > current {
            indentationLevels.append(columns)
            return indentationLevels.count - 1
        }

        while let last = indentationLevels.last, last > columns {
            indentationLevels.removeLast()
        }
        if let exact = indentationLevels.lastIndex(of: columns) {
            return exact
        }

        indentationLevels.append(columns)
        return indentationLevels.count - 1
    }

    private static func leadingIndentColumns(in line: String) -> Int {
        var columns = 0
        for character in line {
            switch character {
            case " ": columns += 1
            case "\t": columns += 4
            default: return columns
            }
        }
        return columns
    }
}
