import Foundation

/// Processor for transforming interleaved content blocks in assistant messages.
///
/// This handles the critical path of converting message.assistant events with
/// mixed content blocks (text, thinking, provider capability_invocation) into properly ordered
/// ChatMessage arrays while preserving streaming order.
///
/// ## Streaming Order Preservation
/// Server sends content blocks in streaming order:
/// ```
/// [thinking, text, capability_invocation, text, capability_invocation]
/// ```
/// This processor preserves that order exactly, producing:
/// ```
/// [ThinkingMsg, TextMsg, CapabilityInvocationMsg, TextMsg, CapabilityInvocationMsg]
/// ```
///
/// ## Content Block Types
/// - `thinking`: Extended thinking content (rendered in ThinkingContentView)
/// - `text`: Regular text response
/// - `capability_invocation`: Provider content block for a capability invocation (combined with capability.invocation.started/completed data)
///
/// ## Interactive Capability Handling
/// `agent::ask_user` is transformed via a dedicated interaction view only when
/// the server-enriched capability identity says the invocation is that
/// contract.
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
        startedInvocations: [String: CapabilityInvocationStartedPayload],
        completedInvocations: [String: CapabilityInvocationCompletedPayload]
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

        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }

            if blockType == ContentBlockType.thinking.rawValue {
                if let message = processThinkingBlock(block, timestamp: timestamp) {
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
            } else if blockType == ContentBlockType.capabilityInvocation.rawValue, let invocationId = block["id"] as? String {
                let started = startedInvocations[invocationId]
                let result = completedInvocations[invocationId]
                let modelPrimitiveName = started?.name ?? (block["name"] as? String) ?? "Unknown"

                let resolvedIdentity = [result?.identity, started?.identity]
                    .compactMap { $0 }
                    .first { !$0.isEmpty }

                if resolvedIdentity?.isUserInteractionCapability == true {
                    if let userInteractionMessage = UserInteractionTransformer.transform(
                        invocationId: invocationId,
                        invocationStart: started,
                        contentBlock: block,
                        timestamp: timestamp,
                        tokenRecord: nil,
                        model: nil,
                        turn: parsed.turn
                    ) {
                        messages.append(userInteractionMessage)
                    }
                    continue
                }

                // Regular capability handling
                if let message = processCapabilityInvocationBlock(
                    block,
                    invocationId: invocationId,
                    invocationStart: started,
                    result: result,
                    modelPrimitiveName: modelPrimitiveName,
                    timestamp: timestamp,
                    parsed: parsed
                ) {
                    messages.append(message)
                }
            }
            // Other block types (redacted, etc.) are skipped
        }

        // Attach turn metadata (tokenRecord, model, latency, thinking) to the LAST
        // message so the stats line renders after all content in the turn — not
        // between text and first capability, or between parallel capability invocations.
        if !messages.isEmpty {
            let lastIdx = messages.count - 1
            messages[lastIdx].tokenRecord = effectiveTokenRecord
            messages[lastIdx].model = parsed.model
            messages[lastIdx].latencyMs = parsed.latencyMs
            messages[lastIdx].stopReason = parsed.stopReason?.rawValue
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
    ///
    /// Metadata (tokenRecord, model, latency, etc.) is NOT set here — it's
    /// attached to the last message after all blocks are processed so the
    /// stats line renders after all capability chips, not in the middle.
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

    /// Process a capability_invocation content block.
    private static func processCapabilityInvocationBlock(
        _ block: [String: Any],
        invocationId: String,
        invocationStart: CapabilityInvocationStartedPayload?,
        result: CapabilityInvocationCompletedPayload?,
        modelPrimitiveName: String,
        timestamp: Date,
        parsed: AssistantMessagePayload
    ) -> ChatMessage? {
        let turn = invocationStart?.turn ?? parsed.turn

        // Determine status based on result
        let status: CapabilityInvocationStatus
        if let result = result {
            status = result.isError ? .error : .success
        } else {
            TronLogger.shared.warning("[RECONSTRUCT] capability_invocation \(modelPrimitiveName) id=\(invocationId) has no matching capability.invocation.completed — will show as running", category: .session)
            status = .running
        }

        // Format result content - show "(no output)" if result is empty
        let resultContent: String?
        if let result = result {
            resultContent = result.content.isEmpty ? "(no output)" : result.content
        } else {
            resultContent = nil
        }

        // Arguments: use capability.invocation.started string if available, else serialize content block input
        let arguments = CapabilityArgumentExtractor.extractArguments(
            invocationStart: invocationStart,
            contentBlock: block
        ) ?? "{}"

        let identity = [result?.identity, invocationStart?.identity]
            .compactMap { $0 }
            .first { !$0.isEmpty }
            ?? CapabilityIdentity()

        // Metadata is set after the loop on the last message (see transform())
        return ChatMessage(
            role: .assistant,
            content: .capabilityInvocation(CapabilityInvocationData(
                id: invocationId,
                status: status,
                arguments: arguments,
                result: resultContent,
                details: result?.details,
                durationMs: result?.durationMs,
                identity: identity
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
