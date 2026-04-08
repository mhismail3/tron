import Foundation

/// Utility methods for event content extraction.
/// Used by EventDeduplicator for duplicate detection.
enum ContentExtractor {

    // MARK: - Text Extraction

    /// Extract text from content (string or content blocks).
    static func extractText(from content: Any?) -> String {
        let parsed = ContentBlockParser.parse(content)
        let joined = parsed.textBlocks.joined()
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Payload-Based Methods (for EventDeduplicator)

    /// Check if payload has tool_use or tool_result blocks.
    static func hasToolBlocks(in payload: [String: AnyCodable]) -> Bool {
        let parsed = ContentBlockParser.parse(payload["content"]?.value)
        return !parsed.toolUseBlocks.isEmpty || !parsed.toolResultBlocks.isEmpty
    }

    /// Extract text content from payload for duplicate matching.
    static func extractTextForMatching(from payload: [String: AnyCodable]) -> String {
        ContentBlockParser.parse(payload["content"]?.value).textBlocks.joined()
    }
}
