import Foundation
import SwiftUI

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
        if let lastUserEvent = events.last(where: { $0.type == PersistedEventType.messageUser.rawValue }) {
            let prompt = extractText(from: lastUserEvent.payload["content"]?.value)
            if !prompt.isEmpty {
                lastUserPrompt = prompt
            }
        }

        // Find the last assistant message and count tools
        if let lastAssistantEvent = events.last(where: { $0.type == PersistedEventType.messageAssistant.rawValue }) {
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
                   let type = block["type"] as? String, type == ContentBlockType.text.rawValue,
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
            if let type = block["type"] as? String, type == ContentBlockType.text.rawValue,
               let text = block["text"] as? String {
                texts.append(text)
            }
        }
        let joined = texts.joined()
        // Strip leading newlines (Anthropic adaptive thinking artifact)
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool Count Extraction

    /// Count tool_use blocks in content.
    static func extractToolCount(from content: Any?) -> Int {
        guard let content = content else { return 0 }

        // String content has no tools
        if content is String { return 0 }

        // Array of content blocks
        if let blocks = content as? [[String: Any]] {
            return blocks.filter { ($0["type"] as? String) == ContentBlockType.toolUse.rawValue }.count
        }

        // Array of Any
        if let blocks = content as? [Any] {
            return blocks.filter { element in
                if let block = element as? [String: Any] {
                    return (block["type"] as? String) == ContentBlockType.toolUse.rawValue
                }
                return false
            }.count
        }

        return 0
    }

    // MARK: - Activity Lines Extraction

    /// Extract activity lines from events for dashboard card display.
    /// Walks ALL session events (not just the last message) to collect activity across
    /// multiple turns — tool calls, text responses, thinking blocks. Returns the last 5 items.
    /// Collected tool result metadata keyed by tool_use_id.
    private struct ToolResultInfo {
        let isError: Bool
        let durationMs: Int?
    }

    static func extractActivityLines(from events: [SessionEvent]) -> [ActivityLine] {
        // Pass 1: collect tool result info by tool_use_id
        // Server stores camelCase keys (toolCallId, isError, duration)
        var toolResults: [String: ToolResultInfo] = [:]
        for event in events where event.type == PersistedEventType.toolResult.rawValue {
            let toolUseId = event.payload["toolCallId"]?.value as? String
                ?? event.payload["tool_use_id"]?.value as? String
            if let toolUseId {
                let isError = (event.payload["isError"]?.value as? Bool)
                    ?? (event.payload["is_error"]?.value as? Bool)
                    ?? false
                let durationMs = (event.payload["duration"]?.value as? Int)
                    ?? (event.payload["duration_ms"]?.value as? Int)
                toolResults[toolUseId] = ToolResultInfo(isError: isError, durationMs: durationMs)
            }
        }

        // Pass 2: walk events in order, building activity lines
        var lines: [ActivityLine] = []

        for event in events {
            switch event.type {
            case PersistedEventType.messageUser.rawValue:
                let text = extractText(from: event.payload["content"]?.value)
                if !text.isEmpty {
                    let firstLine = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
                    let maxLen = DashboardConstants.maxUserPromptLength
                    let truncated = firstLine.count > maxLen ? String(firstLine.prefix(maxLen)) : firstLine
                    lines.append(ActivityLine(kind: .userPrompt, text: truncated.trimmingCharacters(in: .whitespacesAndNewlines)))
                }

            case PersistedEventType.messageAssistant.rawValue:
                guard let content = event.payload["content"]?.value else {
                    continue
                }
                let blocks = contentBlocks(from: content)
                for block in blocks {
                    guard let type = block["type"] as? String else {
                        continue
                    }

                    if type == ContentBlockType.toolUse.rawValue, let name = block["name"] as? String {
                        let descriptor = ToolRegistry.descriptor(for: name)
                        let toolId = block["id"] as? String
                        // Server stores as "arguments", API wire format uses "input"
                        let inputDict = (block["input"] ?? block["arguments"]) as? [String: Any]

                        // Serialize input to JSON for ToolRegistry's summaryExtractor
                        let argsJSON = serializeInput(inputDict)
                        let summary = descriptor.summaryExtractor(argsJSON)

                        // Look up result info
                        let result = toolId.flatMap { toolResults[$0] }
                        let isError = result?.isError ?? false
                        let duration = result?.durationMs.map { SessionStreamBuffer.formatDuration($0) }

                        lines.append(ActivityLine(
                            kind: .toolStart,
                            text: name,
                            icon: descriptor.icon,
                            iconColor: ToolColor(fromDescriptorName: descriptor.iconColorName),
                            toolName: name,
                            displayName: descriptor.displayName,
                            summary: summary.isEmpty ? nil : summary,
                            duration: duration,
                            status: isError ? .error : .success
                        ))

                    } else if type == ContentBlockType.text.rawValue, let text = block["text"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
                            let maxLen = DashboardConstants.maxAssistantTextLength
                            let truncated = firstLine.count > maxLen ? String(firstLine.prefix(maxLen)) : firstLine
                            lines.append(ActivityLine(kind: .text, text: truncated))
                        }

                    } else if type == ContentBlockType.thinking.rawValue {
                        lines.append(ActivityLine(kind: .thinking, text: "Thinking"))
                    }
                }

            default:
                break
            }
        }

        return Array(lines.suffix(DashboardConstants.maxActivityLines))
    }

    /// Serialize tool input dictionary to JSON string for ToolRegistry's summaryExtractor.
    private static func serializeInput(_ input: [String: Any]?) -> String {
        guard let input = input else { return "{}" }
        guard JSONSerialization.isValidJSONObject(input) else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Parse content blocks from a content value (handles both [[String: Any]] and [Any]).
    private static func contentBlocks(from content: Any) -> [[String: Any]] {
        if let blocks = content as? [[String: Any]] { return blocks }
        if let blocks = content as? [Any] { return blocks.compactMap { $0 as? [String: Any] } }
        return []
    }

    /// Extract tool names from content blocks.
    private static func extractToolNames(from content: Any) -> [String] {
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block in
                guard let type = block["type"] as? String,
                      type == ContentBlockType.toolUse.rawValue,
                      let name = block["name"] as? String else { return nil }
                return name
            }
        }
        if let blocks = content as? [Any] {
            return blocks.compactMap { element in
                guard let block = element as? [String: Any],
                      let type = block["type"] as? String,
                      type == ContentBlockType.toolUse.rawValue,
                      let name = block["name"] as? String else { return nil }
                return name
            }
        }
        return []
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
                return blockType == ContentBlockType.toolUse.rawValue || blockType == ContentBlockType.toolResult.rawValue
            }
        }

        // Array of Any (less common)
        if let anyArray = content as? [Any] {
            for element in anyArray {
                if let dict = element as? [String: Any],
                   let type = dict["type"] as? String,
                   type == ContentBlockType.toolUse.rawValue || type == ContentBlockType.toolResult.rawValue {
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
