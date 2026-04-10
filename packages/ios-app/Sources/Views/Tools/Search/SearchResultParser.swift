import Foundation

// MARK: - Search Result Parser

/// Reads structured Search/Grep results from server-provided `tool.details.matches`.
///
/// The server (`packages/agent/src/tools/search/search_tool.rs` +
/// `text_search.rs` / `ast_search.rs`) populates `details.matches` as a flat
/// array of `{filePath, lineNumber, content}` objects. iOS groups them by
/// `filePath` for display. No text parsing.
enum SearchResultParser {

    /// Parse structured matches from tool details into file groups.
    /// Returns an empty array when details are missing or contain no matches.
    static func parse(details: [String: AnyCodable]?) -> [SearchFileGroup] {
        guard let rawMatches = details?.dictArray("matches") else {
            return []
        }

        var groups: [String: [SearchMatch]] = [:]
        var order: [String] = []

        for dict in rawMatches {
            guard let filePath = dict["filePath"] as? String else { continue }
            let lineNumber: Int? = {
                if let i = dict["lineNumber"] as? Int { return i }
                if let d = dict["lineNumber"] as? Double {
                    return Int(exactly: d.rounded(.towardZero))
                }
                return nil
            }()
            let content = (dict["content"] as? String) ?? ""
            if groups[filePath] == nil {
                order.append(filePath)
                groups[filePath] = []
            }
            groups[filePath]?.append(SearchMatch(lineNumber: lineNumber, content: content))
        }

        return order.compactMap { path in
            guard let matches = groups[path] else { return nil }
            return SearchFileGroup(filePath: path, matches: matches)
        }
    }

    /// Calculate line number gutter width based on the highest line number.
    static func lineNumberWidth(for matches: [SearchMatch]) -> CGFloat {
        let maxNum = matches.compactMap(\.lineNumber).max() ?? 0
        let digits = max(String(maxNum).count, 1)
        return CGFloat(max(digits * 8, 14))
    }
}

/// A group of search matches within a single file.
struct SearchFileGroup: Equatable {
    let filePath: String
    let matches: [SearchMatch]
}

/// A single search match: line number + content.
struct SearchMatch: Equatable {
    let lineNumber: Int?
    let content: String
}
