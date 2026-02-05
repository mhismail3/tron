import Foundation

/// Extracts text and metadata from event content blocks.
/// Consolidates duplicated content extraction patterns.
enum ContentExtractor {

    // MARK: - Dashboard Info

    struct DashboardInfo {
        let lastUserPrompt: String?
        let lastAssistantResponse: String?
        let lastToolCount: Int?
    }

    /// Extract dashboard display info from a list of events.
    /// Finds the last user message and last assistant message with tool count.
    static func extractDashboardInfo(from events: [SessionEvent]) -> DashboardInfo {
        var lastUserPrompt: String?
        var lastAssistantResponse: String?
        var lastToolCount: Int?

        // Find the last user message
        if let lastUserEvent = events.last(where: { $0.type == "message.user" }) {
            let prompt = extractText(from: lastUserEvent.payload["content"]?.value)
            if !prompt.isEmpty {
                lastUserPrompt = prompt
            }
        }

        // Find the last assistant message and count tools
        if let lastAssistantEvent = events.last(where: { $0.type == "message.assistant" }) {
            if let content = lastAssistantEvent.payload["content"]?.value {
                lastAssistantResponse = extractText(from: content)
                let toolCount = extractToolCount(from: content)
                if toolCount > 0 {
                    lastToolCount = toolCount
                }
            }
        }

        return DashboardInfo(
            lastUserPrompt: lastUserPrompt,
            lastAssistantResponse: lastAssistantResponse,
            lastToolCount: lastToolCount
        )
    }

    // MARK: - Text Extraction

    /// Extract text from content (string or content blocks).
    static func extractText(from content: Any?) -> String {
        guard let content = content else { return "" }

        // Direct string content
        if let text = content as? String {
            return text
        }

        // Array of content blocks (common format)
        if let blocks = content as? [[String: Any]] {
            return extractTextFromBlocks(blocks)
        }

        // Array of Any (less common but possible)
        if let blocks = content as? [Any] {
            var texts: [String] = []
            for element in blocks {
                if let block = element as? [String: Any],
                   let type = block["type"] as? String, type == "text",
                   let text = block["text"] as? String {
                    texts.append(text)
                }
            }
            return texts.joined()
        }

        return ""
    }

    /// Extract text from an array of content blocks.
    private static func extractTextFromBlocks(_ blocks: [[String: Any]]) -> String {
        var texts: [String] = []
        for block in blocks {
            if let type = block["type"] as? String, type == "text",
               let text = block["text"] as? String {
                texts.append(text)
            }
        }
        let joined = texts.joined()
        // Strip leading newlines (Anthropic adaptive thinking artifact)
        return String(joined.drop(while: \.isNewline))
    }

    // MARK: - Tool Count Extraction

    /// Count tool_use blocks in content.
    static func extractToolCount(from content: Any?) -> Int {
        guard let content = content else { return 0 }

        // String content has no tools
        if content is String { return 0 }

        // Array of content blocks
        if let blocks = content as? [[String: Any]] {
            return blocks.filter { ($0["type"] as? String) == "tool_use" }.count
        }

        // Array of Any
        if let blocks = content as? [Any] {
            return blocks.filter { element in
                if let block = element as? [String: Any] {
                    return (block["type"] as? String) == "tool_use"
                }
                return false
            }.count
        }

        return 0
    }

    // MARK: - Payload-Based Methods (for EventDatabase)

    /// Check if payload has tool_use or tool_result blocks.
    /// Used for deduplication to prefer events with richer content.
    static func hasToolBlocks(in payload: [String: AnyCodable]) -> Bool {
        guard let content = payload["content"]?.value else { return false }

        // Array of content blocks (common format)
        if let contentArray = content as? [[String: Any]] {
            return contentArray.contains { block in
                let blockType = block["type"] as? String
                return blockType == "tool_use" || blockType == "tool_result"
            }
        }

        // Array of Any (less common)
        if let anyArray = content as? [Any] {
            for element in anyArray {
                if let dict = element as? [String: Any],
                   let type = dict["type"] as? String,
                   type == "tool_use" || type == "tool_result" {
                    return true
                }
            }
        }

        return false
    }

    /// Extract text content from payload for duplicate matching.
    /// Returns concatenated text from all text blocks.
    static func extractTextForMatching(from payload: [String: AnyCodable]) -> String {
        guard let content = payload["content"]?.value else { return "" }

        // Direct string content
        if let text = content as? String {
            return text
        }

        // Array of content blocks
        if let contentArray = content as? [[String: Any]] {
            return contentArray.compactMap { $0["text"] as? String }.joined()
        }

        // Array of Any
        if let anyArray = content as? [Any] {
            var texts: [String] = []
            for element in anyArray {
                if let dict = element as? [String: Any],
                   let text = dict["text"] as? String {
                    texts.append(text)
                }
            }
            return texts.joined()
        }

        return ""
    }
}
