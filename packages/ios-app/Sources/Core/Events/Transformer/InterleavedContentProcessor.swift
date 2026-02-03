import Foundation

/// Processor for transforming interleaved content blocks in assistant messages.
///
/// This handles the critical path of converting message.assistant events with
/// mixed content blocks (text, thinking, tool_use) into properly ordered
/// ChatMessage arrays while preserving streaming order.
///
/// ## Streaming Order Preservation
/// Server sends content blocks in streaming order:
/// ```
/// [thinking, text, tool_use, text, tool_use]
/// ```
/// This processor preserves that order exactly, producing:
/// ```
/// [ThinkingMsg, TextMsg, ToolMsg, TextMsg, ToolMsg]
/// ```
///
/// ## Content Block Types
/// - `thinking`: Extended thinking content (rendered in ThinkingContentView)
/// - `text`: Regular text response
/// - `tool_use`: Tool invocation (combined with tool.call/tool.result data)
///
/// ## AskUserQuestion Handling
/// When an `AskUserQuestion` tool is encountered:
/// 1. It's transformed using `AskUserQuestionTransformer` for proper status detection
/// 2. Subsequent text blocks are skipped (AskUserQuestion replaces the response)
enum InterleavedContentProcessor {

    /// Transform an assistant message's content blocks into ChatMessages.
    ///
    /// This generic implementation works with any `EventTransformable` type,
    /// enabling unified processing of both `RawEvent` and `SessionEvent` arrays.
    ///
    /// - Parameters:
    ///   - payload: The message.assistant event payload
    ///   - timestamp: Event timestamp
    ///   - toolCalls: Map of toolCallId -> ToolCallPayload for tool details
    ///   - toolResults: Map of toolCallId -> ToolResultPayload for results
    ///   - allEvents: Optional array of all events for AskUserQuestion status detection
    /// - Returns: Array of ChatMessages in content block order
    static func transform<E: EventTransformable>(
        payload: [String: AnyCodable],
        timestamp: Date,
        toolCalls: [String: ToolCallPayload],
        toolResults: [String: ToolResultPayload],
        allEvents: [E]? = nil
    ) -> [ChatMessage] {
        let parsed = AssistantMessagePayload(from: payload)
        guard let blocks = parsed.contentBlocks else { return [] }

        // Token record from message.assistant payload
        let effectiveTokenRecord = parsed.tokenRecord

        if let record = effectiveTokenRecord {
            TronLogger.shared.debug("[TOKEN-FLOW] iOS: message.assistant reconstruction", category: .events)
            TronLogger.shared.debug("  turn=\(parsed.turn), blocks=\(blocks.count)", category: .events)
            TronLogger.shared.debug("  tokenRecord: newInput=\(record.computed.newInputTokens), contextWindow=\(record.computed.contextWindowTokens), output=\(record.source.rawOutputTokens)", category: .events)
        } else {
            // Server should provide tokenRecord - stats may be missing without it
            TronLogger.shared.warning("[TOKEN-FLOW] iOS: message.assistant MISSING tokenRecord (turn=\(parsed.turn))", category: .events)
        }

        var messages: [ChatMessage] = []
        var sawAskUserQuestion = false  // Track if AskUserQuestion was seen

        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }

            // If AskUserQuestion was already processed, skip subsequent text blocks
            // (the question UI replaces the text response)
            if sawAskUserQuestion && blockType == "text" {
                continue
            }

            if blockType == "thinking" {
                if let message = processThinkingBlock(block, timestamp: timestamp) {
                    messages.append(message)
                }
            } else if blockType == "text" {
                if let message = processTextBlock(
                    block,
                    timestamp: timestamp,
                    tokenRecord: effectiveTokenRecord,
                    parsed: parsed,
                    isFirstMessage: messages.isEmpty
                ) {
                    messages.append(message)
                }
            } else if blockType == "tool_use", let toolUseId = block["id"] as? String {
                let toolCall = toolCalls[toolUseId]
                let result = toolResults[toolUseId]
                let toolName = toolCall?.name ?? (block["name"] as? String) ?? "Unknown"

                // Check if this is AskUserQuestion - handle specially
                if toolName == "AskUserQuestion" {
                    sawAskUserQuestion = true
                    if let askUserMessage = AskUserQuestionTransformer.transform(
                        toolUseId: toolUseId,
                        toolCall: toolCall,
                        contentBlock: block,
                        timestamp: timestamp,
                        tokenRecord: nil,  // Stats only shown on text messages
                        model: nil,
                        turn: parsed.turn,
                        allEvents: allEvents
                    ) {
                        messages.append(askUserMessage)
                    }
                    continue
                }

                // Regular tool handling
                if let message = processToolUseBlock(
                    block,
                    toolUseId: toolUseId,
                    toolCall: toolCall,
                    result: result,
                    toolName: toolName,
                    timestamp: timestamp,
                    parsed: parsed
                ) {
                    messages.append(message)
                }
            }
            // Other block types (redacted, etc.) are skipped
        }

        return messages
    }

    // MARK: - Private Block Processors

    /// Process a thinking content block.
    private static func processThinkingBlock(
        _ block: [String: Any],
        timestamp: Date
    ) -> ChatMessage? {
        guard let thinkingText = block["thinking"] as? String, !thinkingText.isEmpty else {
            return nil
        }

        return ChatMessage(
            role: .assistant,
            content: .thinking(visible: thinkingText, isExpanded: false, isStreaming: false),
            timestamp: timestamp
        )
    }

    /// Process a text content block.
    private static func processTextBlock(
        _ block: [String: Any],
        timestamp: Date,
        tokenRecord: TokenRecord?,
        parsed: AssistantMessagePayload,
        isFirstMessage: Bool
    ) -> ChatMessage? {
        guard let text = block["text"] as? String, !text.isEmpty else {
            return nil
        }

        return ChatMessage(
            role: .assistant,
            content: .text(text),
            timestamp: timestamp,
            tokenRecord: tokenRecord,
            model: parsed.model,
            latencyMs: isFirstMessage ? parsed.latencyMs : nil,
            turnNumber: parsed.turn,
            hasThinking: isFirstMessage ? parsed.hasThinking : nil,
            stopReason: isFirstMessage ? parsed.stopReason?.rawValue : nil
        )
    }

    /// Process a tool_use content block.
    private static func processToolUseBlock(
        _ block: [String: Any],
        toolUseId: String,
        toolCall: ToolCallPayload?,
        result: ToolResultPayload?,
        toolName: String,
        timestamp: Date,
        parsed: AssistantMessagePayload
    ) -> ChatMessage? {
        let turn = toolCall?.turn ?? parsed.turn

        // Determine status based on result
        let status: ToolStatus
        if let result = result {
            status = result.isError ? .error : .success
        } else {
            status = .running
        }

        // Format result content - show "(no output)" if result is empty
        let resultContent: String?
        if let result = result {
            resultContent = result.content.isEmpty ? "(no output)" : result.content
        } else {
            resultContent = nil
        }

        // Arguments: use tool.call string if available, else serialize content block input
        let arguments: String
        if let toolCallArgs = toolCall?.arguments {
            arguments = toolCallArgs
        } else if let inputDict = block["input"] as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: inputDict, options: [.sortedKeys]),
                  let jsonString = String(data: jsonData, encoding: .utf8) {
            arguments = jsonString
        } else {
            arguments = "{}"
        }

        // Tool messages don't show stats - only text responses do
        return ChatMessage(
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: toolName,
                toolCallId: toolUseId,
                arguments: arguments,
                status: status,
                result: resultContent,
                durationMs: result?.durationMs
            )),
            timestamp: timestamp,
            tokenRecord: nil,
            model: nil,
            latencyMs: nil,
            turnNumber: turn,
            hasThinking: nil,
            stopReason: nil
        )
    }
}
