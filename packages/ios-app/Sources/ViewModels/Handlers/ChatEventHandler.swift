import Foundation
import SwiftUI

// MARK: - Result Types

/// Result of handling a text delta
struct TextDeltaResult {
    let accepted: Bool
    let text: String
    let messageId: UUID?
}

/// Result of handling a thinking delta
struct ThinkingDeltaResult {
    let thinkingText: String
}

/// Result of handling a tool start
struct ToolStartResult {
    let tool: ToolUseData
    let isAskUserQuestion: Bool
    let isBrowserTool: Bool
    let isOpenURL: Bool
    let askUserQuestionParams: AskUserQuestionParams?
    let openURL: URL?
}

/// Result of handling a tool end
struct ToolEndResult {
    let toolCallId: String
    let status: ToolStatus
    let result: String
    let durationMs: Int?
    let isAskUserQuestion: Bool
}

/// Result of handling a turn start
struct TurnStartResult {
    let turnNumber: Int
    let stateReset: Bool
}

/// Result of handling a turn end
struct TurnEndResult {
    let turnNumber: Int
    let stopReason: String?
    let tokenRecord: TokenRecord?
    let contextLimit: Int?
    let cost: Double?
    let durationMs: Int?
}

/// Result of handling compaction
struct CompactionResult {
    let tokensBefore: Int
    let tokensAfter: Int
    let reason: String
    let summary: String?
    let estimatedContextTokens: Int?
    var tokensSaved: Int { tokensBefore - tokensAfter }
}

/// Result of handling context cleared
struct ContextClearedResult {
    let tokensBefore: Int
    let tokensAfter: Int
    var tokensFreed: Int { tokensBefore - tokensAfter }
}

/// Result of handling message deleted
struct MessageDeletedResult {
    let targetType: String
    let targetEventId: String
}

/// Result of handling skill removed
struct SkillRemovedResult {
    let skillName: String
}

/// Result of handling agent complete
struct CompleteResult {
    let success: Bool
}

/// Result of handling agent error
struct AgentErrorResult {
    let message: String
}

/// Result of handling UI render start
struct UIRenderStartResult {
    let canvasId: String
    let title: String?
    let toolCallId: String
}

/// Result of handling UI render chunk
struct UIRenderChunkResult {
    let canvasId: String
    let chunk: String
    let accumulated: String
}

/// Result of handling UI render complete
struct UIRenderCompleteResult {
    let canvasId: String
    let ui: [String: AnyCodable]?
    let state: [String: AnyCodable]?
}

/// Result of handling UI render error
struct UIRenderErrorResult {
    let canvasId: String
    let error: String
}

/// Result of handling UI render retry
struct UIRenderRetryResult {
    let canvasId: String
    let attempt: Int
    let errors: String
}

/// Result of handling todos updated
struct TodosUpdatedResult {
    let todos: [RpcTodoItem]
    let restoredCount: Int
}

// MARK: - Event Handler

/// Extracts and processes event data from agent streaming
/// Designed to be testable independently of ChatViewModel
@MainActor
final class ChatEventHandler {

    // MARK: - State

    /// Accumulated streaming text
    private(set) var streamingText: String = ""

    /// Current streaming message ID
    private(set) var streamingMessageId: UUID?

    /// Accumulated thinking text
    private(set) var thinkingText: String = ""

    /// Maximum text length before dropping deltas
    private let maxTextLength = 500_000

    // MARK: - Initialization

    init() {}

    // MARK: - Text Handling

    /// Handle a text delta from streaming
    /// - Parameters:
    ///   - delta: The text delta to process
    ///   - context: The event context for state access
    /// - Returns: Result indicating if delta was accepted and current text
    func handleTextDelta(_ delta: String, context: ChatEventContext) -> TextDeltaResult {
        // Skip if AskUserQuestion was called in this turn
        guard !context.askUserQuestionCalledInTurn else {
            context.logDebug("Skipping text delta - AskUserQuestion was called in this turn")
            return TextDeltaResult(accepted: false, text: streamingText, messageId: streamingMessageId)
        }

        // Check for text limit
        guard streamingText.count + delta.count <= maxTextLength else {
            context.logWarning("Streaming text limit reached, dropping delta")
            return TextDeltaResult(accepted: false, text: streamingText, messageId: streamingMessageId)
        }

        // Create message ID if this is first delta
        if streamingMessageId == nil {
            streamingMessageId = UUID()
        }

        // Accumulate text
        streamingText += delta

        context.logDebug("Text delta received: +\(delta.count) chars, total: \(streamingText.count)")

        return TextDeltaResult(accepted: true, text: streamingText, messageId: streamingMessageId)
    }

    /// Handle a thinking delta from streaming
    /// - Parameter delta: The thinking text delta
    /// - Returns: Result with accumulated thinking text
    func handleThinkingDelta(_ delta: String) -> ThinkingDeltaResult {
        thinkingText += delta
        return ThinkingDeltaResult(thinkingText: thinkingText)
    }

    // MARK: - Tool Handling

    /// Handle a tool start event
    /// - Parameters:
    ///   - pluginResult: The plugin result with tool start data
    ///   - context: The event context
    /// - Returns: Result with tool data and classification
    func handleToolStart(_ pluginResult: ToolStartPlugin.Result, context: ChatEventContext) -> ToolStartResult {
        let toolNameLower = pluginResult.toolName.lowercased()

        // Detect tool types
        let isAskUserQuestion = toolNameLower == "askuserquestion"
        let isBrowserTool = toolNameLower == "browsetheweb"
        let isOpenURL = toolNameLower == "openurl"

        // Parse AskUserQuestion params if applicable
        var askUserQuestionParams: AskUserQuestionParams?
        if isAskUserQuestion {
            if let paramsData = pluginResult.formattedArguments.data(using: .utf8) {
                askUserQuestionParams = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData)
            }
        }

        // Parse OpenURL URL if applicable
        var openURL: URL?
        if isOpenURL {
            if let args = pluginResult.arguments,
               let urlValue = args["url"],
               let urlString = urlValue.value as? String {
                openURL = URL(string: urlString)
            }
        }

        // Create tool data
        let tool = ToolUseData(
            toolName: pluginResult.toolName,
            toolCallId: pluginResult.toolCallId,
            arguments: pluginResult.formattedArguments,
            status: .running
        )

        context.logInfo("Tool started: \(pluginResult.toolName) [\(pluginResult.toolCallId)]")

        return ToolStartResult(
            tool: tool,
            isAskUserQuestion: isAskUserQuestion,
            isBrowserTool: isBrowserTool,
            isOpenURL: isOpenURL,
            askUserQuestionParams: askUserQuestionParams,
            openURL: openURL
        )
    }

    /// Handle a tool end event
    /// - Parameter pluginResult: The plugin result with tool end data
    /// - Returns: Result with updated status and result
    func handleToolEnd(_ pluginResult: ToolEndPlugin.Result) -> ToolEndResult {
        let status: ToolStatus = pluginResult.success ? .success : .error

        return ToolEndResult(
            toolCallId: pluginResult.toolCallId,
            status: status,
            result: pluginResult.displayResult,
            durationMs: pluginResult.durationMs,
            isAskUserQuestion: false  // Caller determines this from message content
        )
    }

    // MARK: - Turn Handling

    /// Handle a turn start event
    /// - Parameter result: The plugin result with turn start data
    /// - Returns: Result indicating turn number and state reset
    func handleTurnStart(_ result: TurnStartPlugin.Result) -> TurnStartResult {
        // Reset streaming state for new turn
        resetStreamingState()

        return TurnStartResult(
            turnNumber: result.turnNumber,
            stateReset: true
        )
    }

    /// Handle a turn end event
    /// - Parameter result: The plugin result with turn end data
    /// - Returns: Result with server-provided values (no local calculation)
    func handleTurnEnd(_ result: TurnEndPlugin.Result) -> TurnEndResult {
        // Pass through server values - NO LOCAL CALCULATION
        return TurnEndResult(
            turnNumber: result.turnNumber,
            stopReason: result.stopReason,
            tokenRecord: result.tokenRecord,
            contextLimit: result.contextLimit,
            cost: result.cost,
            durationMs: result.duration
        )
    }

    // MARK: - State Management

    /// Reset all handler state
    func reset() {
        resetStreamingState()
        thinkingText = ""
    }

    /// Reset streaming state (called at turn boundaries)
    func resetStreamingState() {
        streamingText = ""
        streamingMessageId = nil
    }

    /// Reset thinking state for new block (called after tool completion)
    /// Any subsequent thinking deltas should start a new thinking block
    func resetThinkingState() {
        thinkingText = ""
    }

    /// Finalize current streaming message
    /// - Returns: The final text and message ID, or nil if no streaming message
    func finalizeStreamingMessage() -> (text: String, messageId: UUID)? {
        guard let id = streamingMessageId, !streamingText.isEmpty else {
            return nil
        }

        let result = (text: streamingText, messageId: id)
        resetStreamingState()
        return result
    }

    // MARK: - Compaction Handling

    /// Handle a compaction event
    /// - Parameter result: The plugin result with compaction data
    /// - Returns: Result with token counts
    func handleCompaction(_ result: CompactionPlugin.Result) -> CompactionResult {
        return CompactionResult(
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter,
            reason: result.reason,
            summary: result.summary,
            estimatedContextTokens: result.estimatedContextTokens
        )
    }

    // MARK: - Context Cleared Handling

    /// Handle a context cleared event
    /// - Parameter result: The plugin result with context cleared data
    /// - Returns: Result with token counts
    func handleContextCleared(_ result: ContextClearedPlugin.Result) -> ContextClearedResult {
        return ContextClearedResult(
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter
        )
    }

    // MARK: - Message Deleted Handling

    /// Handle a message deleted event
    /// - Parameter result: The plugin result with deletion info
    /// - Returns: Result with deletion info
    func handleMessageDeleted(_ result: MessageDeletedPlugin.Result) -> MessageDeletedResult {
        return MessageDeletedResult(
            targetType: result.targetType,
            targetEventId: result.targetEventId
        )
    }

    // MARK: - Skill Removed Handling

    /// Handle a skill removed event
    /// - Parameter result: The plugin result with skill name
    /// - Returns: Result with skill name
    func handleSkillRemoved(_ result: SkillRemovedPlugin.Result) -> SkillRemovedResult {
        return SkillRemovedResult(skillName: result.skillName)
    }

    // MARK: - Complete Handling

    /// Handle agent complete event
    /// - Returns: Result indicating success
    func handleComplete() -> CompleteResult {
        // Reset all state on completion
        reset()
        return CompleteResult(success: true)
    }

    // MARK: - Error Handling

    /// Handle agent error event
    /// - Parameter message: The error message
    /// - Returns: Result with error message
    func handleAgentError(_ message: String) -> AgentErrorResult {
        // Reset all state on error
        reset()
        return AgentErrorResult(message: message)
    }

    // MARK: - UI Canvas Handling

    /// Handle UI render start event
    /// - Parameter result: The plugin result with canvas info
    /// - Returns: Result with canvas info
    func handleUIRenderStart(_ result: UIRenderStartPlugin.Result) -> UIRenderStartResult {
        return UIRenderStartResult(
            canvasId: result.canvasId,
            title: result.title,
            toolCallId: result.toolCallId
        )
    }

    /// Handle UI render chunk event
    /// - Parameter result: The plugin result with chunk data
    /// - Returns: Result with chunk data
    func handleUIRenderChunk(_ result: UIRenderChunkPlugin.Result) -> UIRenderChunkResult {
        return UIRenderChunkResult(
            canvasId: result.canvasId,
            chunk: result.chunk,
            accumulated: result.accumulated
        )
    }

    /// Handle UI render complete event
    /// - Parameter result: The plugin result with final UI
    /// - Returns: Result with final UI
    func handleUIRenderComplete(_ result: UIRenderCompletePlugin.Result) -> UIRenderCompleteResult {
        return UIRenderCompleteResult(
            canvasId: result.canvasId,
            ui: result.ui,
            state: result.state
        )
    }

    /// Handle UI render error event
    /// - Parameter result: The plugin result with error info
    /// - Returns: Result with error info
    func handleUIRenderError(_ result: UIRenderErrorPlugin.Result) -> UIRenderErrorResult {
        return UIRenderErrorResult(
            canvasId: result.canvasId,
            error: result.error
        )
    }

    /// Handle UI render retry event
    /// - Parameter result: The plugin result with retry info
    /// - Returns: Result with retry info
    func handleUIRenderRetry(_ result: UIRenderRetryPlugin.Result) -> UIRenderRetryResult {
        return UIRenderRetryResult(
            canvasId: result.canvasId,
            attempt: result.attempt,
            errors: result.errors
        )
    }

    // MARK: - Todo Handling

    /// Handle todos updated event
    /// - Parameter result: The plugin result with todos
    /// - Returns: Result with todos
    func handleTodosUpdated(_ result: TodosUpdatedPlugin.Result) -> TodosUpdatedResult {
        return TodosUpdatedResult(
            todos: result.todos,
            restoredCount: result.restoredCount
        )
    }
}
