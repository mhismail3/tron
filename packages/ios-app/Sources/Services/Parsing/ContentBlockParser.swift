import Foundation

/// Single entry point for parsing event content payloads.
/// Normalizes the three content formats (String, [[String: Any]], [Any]) into
/// a structured result, eliminating the repeated type-checking pattern.
enum ContentBlockParser {

    struct ParsedContent: @unchecked Sendable {
        let textBlocks: [String]
        let toolUseBlocks: [[String: Any]]
        let thinkingBlocks: [[String: Any]]
        let toolResultBlocks: [[String: Any]]
        let allBlocks: [[String: Any]]

        static let empty = ParsedContent(
            textBlocks: [], toolUseBlocks: [], thinkingBlocks: [],
            toolResultBlocks: [], allBlocks: [])
    }

    static func parse(_ content: Any?) -> ParsedContent {
        guard let content else { return .empty }

        // Direct string content
        if let text = content as? String {
            return ParsedContent(textBlocks: [text], toolUseBlocks: [],
                                 thinkingBlocks: [], toolResultBlocks: [], allBlocks: [])
        }

        // Normalize to [[String: Any]]
        let blocks: [[String: Any]]
        if let typed = content as? [[String: Any]] {
            blocks = typed
        } else if let untyped = content as? [Any] {
            blocks = untyped.compactMap { $0 as? [String: Any] }
        } else {
            return .empty
        }

        var text: [String] = []
        var tools: [[String: Any]] = []
        var thinking: [[String: Any]] = []
        var results: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case ContentBlockType.text.rawValue:
                if let t = block["text"] as? String { text.append(t) }
            case ContentBlockType.toolUse.rawValue:
                tools.append(block)
            case ContentBlockType.thinking.rawValue:
                thinking.append(block)
            case ContentBlockType.toolResult.rawValue:
                results.append(block)
            default:
                break
            }
        }

        return ParsedContent(textBlocks: text, toolUseBlocks: tools,
                             thinkingBlocks: thinking, toolResultBlocks: results,
                             allBlocks: blocks)
    }
}
