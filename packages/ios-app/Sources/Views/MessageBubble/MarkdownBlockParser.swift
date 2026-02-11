import Foundation

// MARK: - Markdown Block Types

enum MarkdownBlock: Equatable {
    case header(level: Int, content: String)
    case paragraph(content: String)
    case codeBlock(language: String?, code: String)
    case blockquote(content: String)
    case orderedList(items: [String])
    case unorderedList(items: [String])
    case table(MarkdownTable)
    case horizontalRule
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
                blocks.append(.codeBlock(language: language, code: code))
                continue
            }

            // Horizontal rule (---, ***, ___ with optional spaces, at least 3 chars)
            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
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
                    blocks.append(.table(table))
                } else {
                    // Not a valid table — treat as paragraph
                    blocks.append(.paragraph(content: tableLines.joined(separator: "\n")))
                }
                continue
            }

            // Header (# through ######)
            if let (level, content) = parseHeader(trimmed) {
                blocks.append(.header(level: level, content: content))
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
                blocks.append(.blockquote(content: quoteLines.joined(separator: "\n")))
                continue
            }

            // Unordered list (- or * or + prefix)
            if isUnorderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let ll = lines[i]
                    let lt = ll.trimmingCharacters(in: .whitespaces)
                    if lt.isEmpty { break }
                    if isUnorderedListItem(lt) {
                        items.append(stripListMarker(lt))
                    } else if ll.hasPrefix("  ") || ll.hasPrefix("\t") {
                        // Continuation of previous item
                        if !items.isEmpty {
                            items[items.count - 1] += " " + lt
                        }
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.unorderedList(items: items))
                continue
            }

            // Ordered list (1. 2. etc.)
            if isOrderedListItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let ll = lines[i]
                    let lt = ll.trimmingCharacters(in: .whitespaces)
                    if lt.isEmpty { break }
                    if isOrderedListItem(lt) {
                        items.append(stripOrderedListMarker(lt))
                    } else if ll.hasPrefix("  ") || ll.hasPrefix("\t") {
                        // Continuation of previous item
                        if !items.isEmpty {
                            items[items.count - 1] += " " + lt
                        }
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.orderedList(items: items))
                continue
            }

            // Paragraph — accumulate consecutive non-empty, non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let pl = lines[i]
                let pt = pl.trimmingCharacters(in: .whitespaces)
                if pt.isEmpty { break }
                if pt.hasPrefix("```") || pt.hasPrefix("#") || pt.hasPrefix(">")
                    || isUnorderedListItem(pt) || isOrderedListItem(pt)
                    || isHorizontalRule(pt) || MarkdownTableParser.isTableLine(pt) { break }
                paraLines.append(pl)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(content: paraLines.joined(separator: "\n")))
            }
        }

        return blocks
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

    private static func isUnorderedListItem(_ line: String) -> Bool {
        let prefixes = ["- ", "* ", "+ "]
        return prefixes.contains(where: { line.hasPrefix($0) })
    }

    private static func isOrderedListItem(_ line: String) -> Bool {
        // Match "1. ", "2. ", "10. " etc.
        guard let dotIndex = line.firstIndex(of: ".") else { return false }
        let prefix = line[line.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return false }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return false }
        return true
    }

    private static func stripListMarker(_ line: String) -> String {
        // Remove "- ", "* ", "+ " prefix
        guard line.count >= 2 else { return line }
        return String(line.dropFirst(2))
    }

    private static func stripOrderedListMarker(_ line: String) -> String {
        // Remove "1. ", "10. " etc.
        guard let dotIndex = line.firstIndex(of: ".") else { return line }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex else { return "" }
        return String(line[line.index(after: afterDot)...]).trimmingCharacters(in: .init(charactersIn: " "))
    }
}
