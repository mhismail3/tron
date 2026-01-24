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
    let isOpenBrowser: Bool
    let askUserQuestionParams: AskUserQuestionParams?
    let openBrowserURL: URL?
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
    /// Server-provided normalized token usage (preferred)
    let normalizedUsage: NormalizedTokenUsage?
    /// Raw token usage (for backward compatibility)
    let tokenUsage: TokenUsage?
    let contextLimit: Int?
    let cost: Double?
    let durationMs: Int?
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
    ///   - event: The tool start event
    ///   - context: The event context
    /// - Returns: Result with tool data and classification
    func handleToolStart(_ event: ToolStartEvent, context: ChatEventContext) -> ToolStartResult {
        let toolNameLower = event.toolName.lowercased()

        // Detect tool types
        let isAskUserQuestion = toolNameLower == "askuserquestion"
        let isBrowserTool = toolNameLower.contains("browser")
        let isOpenBrowser = toolNameLower == "openbrowser"

        // Parse AskUserQuestion params if applicable
        var askUserQuestionParams: AskUserQuestionParams?
        if isAskUserQuestion {
            if let paramsData = event.formattedArguments.data(using: .utf8) {
                askUserQuestionParams = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData)
            }
        }

        // Parse OpenBrowser URL if applicable
        var openBrowserURL: URL?
        if isOpenBrowser {
            if let args = event.arguments,
               let urlValue = args["url"],
               let urlString = urlValue.value as? String {
                openBrowserURL = URL(string: urlString)
            }
        }

        // Create tool data
        let tool = ToolUseData(
            toolName: event.toolName,
            toolCallId: event.toolCallId,
            arguments: event.formattedArguments,
            status: .running
        )

        context.logInfo("Tool started: \(event.toolName) [\(event.toolCallId)]")

        return ToolStartResult(
            tool: tool,
            isAskUserQuestion: isAskUserQuestion,
            isBrowserTool: isBrowserTool,
            isOpenBrowser: isOpenBrowser,
            askUserQuestionParams: askUserQuestionParams,
            openBrowserURL: openBrowserURL
        )
    }

    /// Handle a tool end event
    /// - Parameter event: The tool end event
    /// - Returns: Result with updated status and result
    func handleToolEnd(_ event: ToolEndEvent) -> ToolEndResult {
        let status: ToolStatus = event.success ? .success : .error

        return ToolEndResult(
            toolCallId: event.toolCallId,
            status: status,
            result: event.displayResult,
            durationMs: event.durationMs,
            isAskUserQuestion: false  // Caller determines this from message content
        )
    }

    // MARK: - Turn Handling

    /// Handle a turn start event
    /// - Parameter event: The turn start event
    /// - Returns: Result indicating turn number and state reset
    func handleTurnStart(_ event: TurnStartEvent) -> TurnStartResult {
        // Reset streaming state for new turn
        resetStreamingState()

        return TurnStartResult(
            turnNumber: event.turnNumber,
            stateReset: true
        )
    }

    /// Handle a turn end event
    /// - Parameter event: The turn end event
    /// - Returns: Result with server-provided values (no local calculation)
    func handleTurnEnd(_ event: TurnEndEvent) -> TurnEndResult {
        // Pass through server values - NO LOCAL CALCULATION
        return TurnEndResult(
            turnNumber: event.turnNumber,
            stopReason: event.stopReason,
            normalizedUsage: event.normalizedUsage,
            tokenUsage: event.tokenUsage,
            contextLimit: event.contextLimit,
            cost: event.cost,
            durationMs: event.data?.duration
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
}
