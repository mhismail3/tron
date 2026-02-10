import Foundation

/// Typed message search utility to eliminate duplicated search patterns across ChatViewModel extensions.
/// Provides efficient, type-safe lookups for common message finding operations.
enum MessageFinder {

    // MARK: - By Message ID

    /// Find message index by UUID
    static func indexById(_ id: UUID, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex(where: { $0.id == id })
    }

    // MARK: - By Event ID

    /// Find message index by eventId
    static func indexByEventId(_ eventId: String, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex(where: { $0.eventId == eventId })
    }

    // MARK: - By Tool Call ID

    /// Find LAST message index with matching toolCallId in toolUse content.
    static func lastIndexOfToolUse(toolCallId: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            if case .toolUse(let tool) = message.content {
                return tool.toolCallId == toolCallId
            }
            return false
        })
    }

    /// Find LAST message index with matching toolCallId in toolResult content.
    static func lastIndexOfToolResult(toolCallId: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            if case .toolResult(let result) = message.content {
                return result.toolCallId == toolCallId
            }
            return false
        })
    }

    /// Check if a message with this toolCallId already exists (toolUse, toolResult, or subagent).
    /// Used to prevent duplicate tool messages during catch-up + streaming.
    /// Includes `.subagent` because reconstruction converts SpawnSubagent `.toolUse` → `.subagent`.
    static func hasToolMessage(toolCallId: String, in messages: [ChatMessage]) -> Bool {
        messages.contains(where: { message in
            switch message.content {
            case .toolUse(let tool):
                return tool.toolCallId == toolCallId
            case .toolResult(let result):
                return result.toolCallId == toolCallId
            case .subagent(let data):
                return data.toolCallId == toolCallId
            default:
                return false
            }
        })
    }

    // MARK: - By AskUserQuestion

    /// Find LAST message index with matching toolCallId in askUserQuestion content.
    static func lastIndexOfAskUserQuestion(toolCallId: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            if case .askUserQuestion(let data) = message.content {
                return data.toolCallId == toolCallId
            }
            return false
        })
    }

    // MARK: - By RenderAppUI

    /// Find LAST message index with matching toolCallId for RenderAppUI or toolUse(renderappui).
    static func lastIndexOfRenderAppUI(toolCallId: String, in messages: [ChatMessage]) -> Int? {
        messages.lastIndex(where: { message in
            switch message.content {
            case .renderAppUI(let chipData):
                return chipData.toolCallId == toolCallId
            case .toolUse(let tool):
                return tool.toolCallId == toolCallId && ToolKind(toolName: tool.toolName) == .renderAppUI
            default:
                return false
            }
        })
    }

    // MARK: - By Subagent

    /// Find message index by subagentSessionId in subagent content.
    static func indexBySubagentSessionId(_ sessionId: String, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex(where: { message in
            if case .subagent(let data) = message.content {
                return data.subagentSessionId == sessionId
            }
            return false
        })
    }

    /// Find message index for SpawnSubagent tool by toolCallId.
    static func indexOfSpawnSubagentTool(toolCallId: String, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex(where: { message in
            if case .toolUse(let tool) = message.content {
                return tool.toolCallId == toolCallId && tool.toolName == "SpawnSubagent"
            }
            return false
        })
    }
}
