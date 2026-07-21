import Foundation

/// Processor for transforming interleaved content blocks in assistant messages.
///
/// This handles the critical path of converting message.assistant events with
/// mixed content blocks (text, thinking, provider tool_invocation) into properly ordered
/// ChatMessage arrays while preserving streaming order.
///
/// ## Streaming Order Preservation
/// Server sends content blocks in streaming order:
/// ```
/// [thinking, text, tool_invocation, text, tool_invocation]
/// ```
/// This processor preserves that order exactly, producing:
/// ```
/// [ThinkingMsg, TextMsg, ToolInvocationMsg, TextMsg, ToolInvocationMsg]
/// ```
///
/// ## Content Block Types
/// - `thinking`: Extended thinking content (rendered in ThinkingContentView)
/// - `text`: Regular text response
/// - `tool_invocation`: Provider content block for a tool invocation (combined with tool.invocation.started/completed data)
///
enum InterleavedContentProcessor {

    /// Transform an assistant message's content blocks into ChatMessages.
    ///
    /// - Parameters:
    ///   - payload: The message.assistant event payload
    ///   - timestamp: Event timestamp
    ///   - startedInvocations: Map of invocation id -> started payload
    ///   - completedInvocations: Map of invocation id -> completed payload
    /// - Returns: Array of ChatMessages in content block order
    static func transform(
        payload: [String: AnyCodable],
        timestamp: Date,
        startedInvocations: [String: ToolInvocationStartedPayload],
        completedInvocations: [String: ToolInvocationCompletedPayload]
    ) -> [ChatMessage] {
        guard let parsed = AssistantMessagePayload(from: payload) else {
            return []
        }
        let blocks = parsed.contentBlocks

        // Token record from message.assistant payload
        let effectiveTokenRecord = parsed.tokenRecord

        if let record = effectiveTokenRecord {
            #if DEBUG || BETA
            TronLogger.shared.debug("[TOKEN-FLOW] iOS: message.assistant reconstruction", category: .events)
            TronLogger.shared.debug("  turn=\(parsed.turn), blocks=\(blocks.count)", category: .events)
            TronLogger.shared.debug("  tokenRecord: newInput=\(record.computed.newInputTokens), contextWindow=\(record.computed.contextWindowTokens), output=\(record.source.rawOutputTokens)", category: .events)
            #endif
        } else {
            TronLogger.shared.warning("[TOKEN-FLOW] iOS: message.assistant MISSING tokenRecord (turn=\(parsed.turn))", category: .events)
        }

        var messages: [ChatMessage] = []
        var emittedThinkingSnapshots = Set<String>()

        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }

            if blockType == ContentBlockType.thinking.rawValue {
                if let message = processThinkingBlock(
                    block,
                    timestamp: timestamp,
                    emittedSnapshots: &emittedThinkingSnapshots
                ) {
                    messages.append(message)
                }
            } else if blockType == ContentBlockType.text.rawValue {
                if let message = processTextBlock(
                    block,
                    timestamp: timestamp,
                    parsed: parsed
                ) {
                    messages.append(message)
                }
            } else if blockType == ContentBlockType.toolInvocation.rawValue, let invocationId = block["id"] as? String {
                let started = startedInvocations[invocationId]
                let result = completedInvocations[invocationId]
                let toolName = started?.name ?? (block["name"] as? String) ?? "Unknown"

                if let message = processToolInvocationBlock(
                    block,
                    invocationId: invocationId,
                    invocationStart: started,
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

        // Provider stop reasons do not identify finality: `end_turn` can arrive
        // with tool drafts. Only completed no-tool text is
        // guaranteed to be the final response and eligible for a stats row.
        if parsed.isFinalAssistantResponse,
           let responseIndex = messages.lastIndex(where: { $0.content.isAssistantResponseText }) {
            messages[responseIndex].isFinalAssistantResponse = true
            messages[responseIndex].applyFinalAssistantResponseMetadata(
                tokenRecord: effectiveTokenRecord,
                model: parsed.model,
                latencyMs: parsed.latencyMs
            )
        }

        return messages
    }

    // MARK: - Private Block Processors

    /// Process a thinking content block.
    private static func processThinkingBlock(
        _ block: [String: Any],
        timestamp: Date,
        emittedSnapshots: inout Set<String>
    ) -> ChatMessage? {
        guard let thinkingText = block["thinking"] as? String, !thinkingText.isEmpty else {
            return nil
        }
        let normalized = thinkingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, emittedSnapshots.insert(normalized).inserted else {
            return nil
        }
        let kind = ThinkingDisplayKind(serverValue: block["kind"] as? String)

        return ChatMessage(
            role: .assistant,
            content: .thinking(
                visible: thinkingText,
                isExpanded: false,
                isStreaming: false,
                kind: kind
            ),
            timestamp: timestamp
        )
    }

    /// Process a text content block.
    ///
    /// Metadata is attached after all blocks are processed, and only when the
    /// payload is the final no-tool response for the prompt cycle.
    private static func processTextBlock(
        _ block: [String: Any],
        timestamp: Date,
        parsed: AssistantMessagePayload
    ) -> ChatMessage? {
        guard let rawText = block["text"] as? String, !rawText.isEmpty else {
            return nil
        }
        // Strip leading newlines (Anthropic adaptive thinking artifact)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .text(text),
            timestamp: timestamp,
            turnNumber: parsed.turn
        )
    }

    /// Process a tool_invocation content block.
    private static func processToolInvocationBlock(
        _ block: [String: Any],
        invocationId: String,
        invocationStart: ToolInvocationStartedPayload?,
        result: ToolInvocationCompletedPayload?,
        toolName: String,
        timestamp: Date,
        parsed: AssistantMessagePayload
    ) -> ChatMessage? {
        let turn = invocationStart?.turn ?? parsed.turn

        // Determine status based on result
        let status: ToolInvocationStatus
        if let result = result {
            status = result.isError ? .error : .success
        } else {
            TronLogger.shared.warning("[RECONSTRUCT] tool_invocation \(toolName) id=\(invocationId) has no matching tool.invocation.completed — will show as running", category: .session)
            status = .running
        }

        // Format result content - show "(no output)" if result is empty
        let resultContent: String?
        if let result = result {
            resultContent = result.content.isEmpty ? "(no output)" : result.content
        } else {
            resultContent = nil
        }

        // Arguments: use tool.invocation.started string if available, else serialize content block input
        let arguments = ToolArgumentExtractor.extractArguments(
            invocationStart: invocationStart,
            contentBlock: block
        ) ?? "{}"

        let identity = [result?.identity, invocationStart?.identity]
            .compactMap { $0 }
            .first { !$0.isEmpty }
            ?? ToolIdentity()

        return ChatMessage(
            role: .assistant,
            content: .toolInvocation(ToolInvocationData(
                id: invocationId,
                status: status,
                arguments: arguments,
                result: resultContent,
                details: result?.details,
                durationMs: result?.durationMs,
                identity: identity,
                errorClassification: result?.failure.map(ToolErrorClassification.init(failure:))
            )),
            timestamp: timestamp,
            tokenRecord: nil,
            model: nil,
            latencyMs: nil,
            turnNumber: turn,
            hasThinking: nil
        )
    }
}
