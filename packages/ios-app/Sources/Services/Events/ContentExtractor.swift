import Foundation
import SwiftUI

/// Extracts text and metadata from event content blocks.
/// Delegates content format normalization to ContentBlockParser.
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

        if let lastUserEvent = events.last(where: { $0.type == PersistedEventType.messageUser.rawValue }) {
            let prompt = extractText(from: lastUserEvent.payload["content"]?.value)
            if !prompt.isEmpty {
                lastUserPrompt = prompt
            }
        }

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
        let parsed = ContentBlockParser.parse(content)
        let joined = parsed.textBlocks.joined()
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool Count Extraction

    /// Count tool_use blocks in content.
    static func extractToolCount(from content: Any?) -> Int {
        ContentBlockParser.parse(content).toolUseBlocks.count
    }

    // MARK: - Activity Lines Extraction

    /// Extract activity lines from events for dashboard card display.
    /// Walks ALL session events to collect activity across multiple turns.
    private struct ToolResultInfo {
        let isError: Bool
        let durationMs: Int?
    }

    static func extractActivityLines(from events: [SessionEvent]) -> [ActivityLine] {
        // Pass 1: collect tool result info by tool_use_id
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
                guard let content = event.payload["content"]?.value else { continue }
                let parsed = ContentBlockParser.parse(content)

                // Walk allBlocks in original order to preserve interleaving
                // (text before tool calls, tool calls between text, etc.)
                for block in parsed.allBlocks {
                    guard let type = block["type"] as? String else { continue }

                    if type == ContentBlockType.toolUse.rawValue, let name = block["name"] as? String {
                        let descriptor = ToolRegistry.descriptor(for: name)
                        let toolId = block["id"] as? String
                        let inputDict = (block["input"] ?? block["arguments"]) as? [String: Any]
                        let argsJSON = serializeInput(inputDict)
                        let summary = descriptor.summaryExtractor(argsJSON)

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

    // MARK: - Payload-Based Methods (for EventDatabase)

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
