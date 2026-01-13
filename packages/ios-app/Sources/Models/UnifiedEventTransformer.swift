import Foundation

// =============================================================================
// MARK: - Unified Event Transformer
// =============================================================================

/// The single source of truth for transforming server events into ChatMessages.
///
/// This transformer handles BOTH:
/// 1. Persisted events (from `events.getHistory` RPC / SQLite)
/// 2. Streaming events (from WebSocket during live agent execution)
///
/// ## Architecture Principle
/// **Content block order is the source of truth for interleaving.**
///
/// The server sends `message.assistant` events with content blocks in exact
/// streaming order via `currentTurnContentSequence`. This preserves the interleaving
/// of text and tool calls as they appeared during streaming:
///
/// ```
/// [text: "I'll run sleep 3...", tool_use: {id: "t1"}, text: "Done!", ...]
/// ```
///
/// Tool details come from separate `tool.call` events (name, arguments, turn).
/// Tool results come from `tool.result` events. Both are combined when rendering
/// tool_use content blocks from the message.assistant.
///
/// ## Usage
/// ```swift
/// // For persisted events (history, session preview):
/// let messages = UnifiedEventTransformer.transformPersistedEvents(rawEvents)
///
/// // For streaming events (live chat):
/// if let message = UnifiedEventTransformer.transformStreamingEvent(type, data) {
///     messages.append(message)
/// }
/// ```
struct UnifiedEventTransformer {

    // =========================================================================
    // MARK: - Persisted Event Transformation
    // =========================================================================

    /// Transform an array of persisted events to ChatMessages.
    ///
    /// This is the primary method for converting server event history to
    /// displayable messages. Events are sorted by turn number (from payload),
    /// then by event type within each turn (text before tools) to preserve
    /// the logical order of Claude's responses.
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: Raw events from `events.getHistory` RPC
    /// - Returns: Array of ChatMessages in chronological order
    static func transformPersistedEvents(_ events: [RawEvent]) -> [ChatMessage] {
        // Sort by turn number, then timestamp, then sequence
        let sorted = sortEventsByTurn(events)

        // Build maps for tool calls and results
        var toolCalls: [String: ToolCallPayload] = [:]
        var toolResults: [String: ToolResultPayload] = [:]
        for event in sorted {
            if event.type == PersistedEventType.toolCall.rawValue,
               let payload = ToolCallPayload(from: event.payload) {
                toolCalls[payload.toolCallId] = payload
            }
            if event.type == PersistedEventType.toolResult.rawValue,
               let payload = ToolResultPayload(from: event.payload) {
                toolResults[payload.toolCallId] = payload
            }
        }

        // Transform events, processing message.assistant content blocks in order
        var messages: [ChatMessage] = []
        for event in sorted {
            // Skip tool.call and tool.result - they're processed via message.assistant content blocks
            if event.type == PersistedEventType.toolCall.rawValue ||
               event.type == PersistedEventType.toolResult.rawValue {
                continue
            }

            // message.assistant: process content blocks in order (preserves interleaving)
            if event.type == PersistedEventType.messageAssistant.rawValue {
                let interleaved = transformAssistantMessageInterleaved(
                    event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults
                )
                messages.append(contentsOf: interleaved)
            } else {
                if let msg = transformPersistedEvent(event) {
                    messages.append(msg)
                }
            }
        }

        return messages
    }

    /// Transform an array of SessionEvents (from EventDatabase) to ChatMessages.
    ///
    /// Overload that accepts SessionEvent from the local SQLite database.
    /// SessionEvent includes additional fields like parentId, sessionId, etc.
    /// but uses the same core fields (type, timestamp, payload) for transformation.
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: SessionEvents from EventDatabase
    /// - Returns: Array of ChatMessages in chronological order
    static func transformPersistedEvents(_ events: [SessionEvent]) -> [ChatMessage] {
        // Sort by turn number, then timestamp, then sequence
        let sorted = sortEventsByTurn(events)

        // Build maps for tool calls and results
        var toolCalls: [String: ToolCallPayload] = [:]
        var toolResults: [String: ToolResultPayload] = [:]
        for event in sorted {
            if event.type == PersistedEventType.toolCall.rawValue,
               let payload = ToolCallPayload(from: event.payload) {
                toolCalls[payload.toolCallId] = payload
            }
            if event.type == PersistedEventType.toolResult.rawValue,
               let payload = ToolResultPayload(from: event.payload) {
                toolResults[payload.toolCallId] = payload
            }
        }

        // Transform events, processing message.assistant content blocks in order
        var messages: [ChatMessage] = []
        for event in sorted {
            // Skip tool.call and tool.result - they're processed via message.assistant content blocks
            if event.type == PersistedEventType.toolCall.rawValue ||
               event.type == PersistedEventType.toolResult.rawValue {
                continue
            }

            // message.assistant: process content blocks in order (preserves interleaving)
            if event.type == PersistedEventType.messageAssistant.rawValue {
                let interleaved = transformAssistantMessageInterleaved(
                    event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults
                )
                messages.append(contentsOf: interleaved)
            } else {
                if let msg = transformPersistedEvent(type: event.type, timestamp: event.timestamp, payload: event.payload) {
                    messages.append(msg)
                }
            }
        }

        return messages
    }

    /// Transform a single SessionEvent (from EventDatabase) to a ChatMessage.
    static func transformPersistedEvent(_ event: SessionEvent) -> ChatMessage? {
        transformPersistedEvent(type: event.type, timestamp: event.timestamp, payload: event.payload)
    }

    /// Internal helper: transform by extracting common fields.
    private static func transformPersistedEvent(
        type: String,
        timestamp: String,
        payload: [String: AnyCodable]
    ) -> ChatMessage? {
        guard let eventType = PersistedEventType(rawValue: type) else {
            logger.warning("Unknown persisted event type: \(type)", category: .events)
            return nil
        }

        // Skip events that don't render as chat messages
        guard eventType.rendersAsChatMessage else { return nil }

        let ts = parseTimestamp(timestamp)

        switch eventType {
        case .messageUser:
            return transformUserMessage(payload, timestamp: ts)
        case .messageAssistant:
            return transformAssistantMessage(payload, timestamp: ts)
        case .messageSystem:
            return transformSystemMessage(payload, timestamp: ts)
        case .toolCall:
            return transformToolCall(payload, timestamp: ts)
        case .toolResult:
            return transformToolResult(payload, timestamp: ts)
        case .notificationInterrupted:
            return transformInterrupted(payload, timestamp: ts)
        case .configModelSwitch:
            return transformModelSwitch(payload, timestamp: ts)
        case .configReasoningLevel:
            return transformReasoningLevelChange(payload, timestamp: ts)
        case .errorAgent:
            return transformAgentError(payload, timestamp: ts)
        case .errorTool:
            return transformToolError(payload, timestamp: ts)
        case .errorProvider:
            return transformProviderError(payload, timestamp: ts)
        case .contextCleared:
            return transformContextCleared(payload, timestamp: ts)
        case .skillRemoved:
            return transformSkillRemoved(payload, timestamp: ts)
        default:
            return nil
        }
    }

    /// Transform a single persisted event (RawEvent from RPC) to a ChatMessage.
    ///
    /// Returns nil for events that don't render as messages (metadata events,
    /// streaming deltas, etc.)
    ///
    /// - Parameter event: A raw event from the server
    /// - Returns: ChatMessage if this event should be displayed, nil otherwise
    static func transformPersistedEvent(_ event: RawEvent) -> ChatMessage? {
        transformPersistedEvent(type: event.type, timestamp: event.timestamp, payload: event.payload)
    }

    // =========================================================================
    // MARK: - Persisted Event Handlers
    // =========================================================================

    private static func transformUserMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = UserMessagePayload(from: payload) else { return nil }

        // Skip tool_result context messages - they're LLM conversation context,
        // not displayable user messages. Tool results are displayed via tool.result events.
        if parsed.isToolResultContext {
            return nil
        }

        // Skip empty user messages (unless they have attachments or skills)
        guard !parsed.content.isEmpty || parsed.attachments != nil || parsed.skills != nil else { return nil }

        return ChatMessage(
            role: .user,
            content: .text(parsed.content),
            timestamp: timestamp,
            attachments: parsed.attachments,
            skills: parsed.skills
        )
    }

    private static func transformAssistantMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let parsed = AssistantMessagePayload(from: payload)

        // CRITICAL: Only extract TEXT from assistant messages
        // Tool blocks are handled by tool.call/tool.result events
        guard let text = parsed.textContent, !text.isEmpty else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .text(text),
            timestamp: timestamp,
            tokenUsage: parsed.tokenUsage,
            model: parsed.model,
            latencyMs: parsed.latencyMs,
            turnNumber: parsed.turn,
            hasThinking: parsed.hasThinking,
            stopReason: parsed.stopReason?.rawValue
        )
    }

    /// Transform a message.assistant event's content blocks into ordered ChatMessages.
    ///
    /// This is the key function for preserving interleaved text and tool calls.
    /// The server sends content blocks in exact streaming order via `currentTurnContentSequence`.
    /// We process each block in order, creating separate messages for text and tool use.
    ///
    /// - Parameters:
    ///   - payload: The message.assistant event payload
    ///   - timestamp: Event timestamp
    ///   - toolCalls: Map of toolCallId -> ToolCallPayload for tool details
    ///   - toolResults: Map of toolCallId -> ToolResultPayload for results
    /// - Returns: Array of ChatMessages in content block order
    private static func transformAssistantMessageInterleaved(
        _ payload: [String: AnyCodable],
        timestamp: Date,
        toolCalls: [String: ToolCallPayload],
        toolResults: [String: ToolResultPayload]
    ) -> [ChatMessage] {
        let parsed = AssistantMessagePayload(from: payload)
        guard let blocks = parsed.contentBlocks else { return [] }

        var messages: [ChatMessage] = []

        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }

            if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                // Create text message - only first message gets metadata
                messages.append(ChatMessage(
                    role: .assistant,
                    content: .text(text),
                    timestamp: timestamp,
                    tokenUsage: messages.isEmpty ? parsed.tokenUsage : nil,
                    model: messages.isEmpty ? parsed.model : nil,
                    latencyMs: messages.isEmpty ? parsed.latencyMs : nil,
                    turnNumber: parsed.turn,
                    hasThinking: messages.isEmpty ? parsed.hasThinking : nil,
                    stopReason: messages.isEmpty ? parsed.stopReason?.rawValue : nil
                ))
            } else if blockType == "tool_use", let toolUseId = block["id"] as? String {
                // Find matching tool.call for full details, fall back to content block info
                let toolCall = toolCalls[toolUseId]
                let result = toolResults[toolUseId]

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

                // Use tool.call details if available, otherwise fall back to content block
                let toolName = toolCall?.name ?? (block["name"] as? String) ?? "Unknown"
                let turn = toolCall?.turn ?? parsed.turn

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

                // First message of turn gets metadata (for token tracking on session restore)
                messages.append(ChatMessage(
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
                    tokenUsage: messages.isEmpty ? parsed.tokenUsage : nil,
                    model: messages.isEmpty ? parsed.model : nil,
                    latencyMs: messages.isEmpty ? parsed.latencyMs : nil,
                    turnNumber: turn,
                    hasThinking: messages.isEmpty ? parsed.hasThinking : nil,
                    stopReason: messages.isEmpty ? parsed.stopReason?.rawValue : nil
                ))
            }
            // Skip thinking blocks and other types - they're handled elsewhere
        }

        return messages
    }

    private static func transformSystemMessage(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = SystemMessagePayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .text(parsed.content),
            timestamp: timestamp
        )
    }

    private static func transformToolCall(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolCallPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: parsed.name,
                toolCallId: parsed.toolCallId,
                arguments: parsed.arguments,
                status: .success  // Will be updated by tool.result
            )),
            timestamp: timestamp,
            turnNumber: parsed.turn
        )
    }


    private static func transformToolResult(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolResultPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .toolResult,
            content: .toolResult(ToolResultData(
                toolCallId: parsed.toolCallId,
                content: parsed.content,
                isError: parsed.isError,
                toolName: parsed.name,
                arguments: parsed.arguments,
                durationMs: parsed.durationMs
            )),
            timestamp: timestamp
        )
    }

    private static func transformInterrupted(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        return ChatMessage(
            role: .system,
            content: .interrupted,
            timestamp: timestamp
        )
    }

    private static func transformModelSwitch(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ModelSwitchPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .modelChange(
                from: formatModelDisplayName(parsed.previousModel),
                to: formatModelDisplayName(parsed.newModel)
            ),
            timestamp: timestamp
        )
    }

    private static func transformReasoningLevelChange(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        let parsed = ReasoningLevelPayload(from: payload)

        // Need both previous and new levels to show a meaningful notification
        guard let previousLevel = parsed.previousLevel,
              let newLevel = parsed.newLevel else { return nil }

        return ChatMessage(
            role: .system,
            content: .reasoningLevelChange(
                from: previousLevel.capitalized,
                to: newLevel.capitalized
            ),
            timestamp: timestamp
        )
    }

    private static func transformAgentError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = AgentErrorPayload(from: payload) else { return nil }

        let errorText = parsed.code != nil
            ? "[\(parsed.code!)] \(parsed.error)"
            : parsed.error

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    private static func transformToolError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ToolErrorPayload(from: payload) else { return nil }

        var errorText = "Tool '\(parsed.toolName)' failed: \(parsed.error)"
        if let code = parsed.code {
            errorText = "[\(code)] \(errorText)"
        }

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    private static func transformProviderError(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ProviderErrorPayload(from: payload) else { return nil }

        var errorText = "\(parsed.provider) error: \(parsed.error)"
        if let code = parsed.code {
            errorText = "[\(code)] \(errorText)"
        }
        if parsed.retryable, let retryAfter = parsed.retryAfter {
            errorText += " (retrying in \(retryAfter)ms)"
        }

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    private static func transformContextCleared(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = ContextClearedPayload(from: payload) else { return nil }

        return ChatMessage(
            role: .system,
            content: .contextCleared(
                tokensBefore: parsed.tokensBefore,
                tokensAfter: parsed.tokensAfter
            ),
            timestamp: timestamp
        )
    }

    private static func transformSkillRemoved(
        _ payload: [String: AnyCodable],
        timestamp: Date
    ) -> ChatMessage? {
        guard let skillName = payload["skillName"]?.value as? String else { return nil }

        return ChatMessage(
            role: .system,
            content: .skillRemoved(skillName: skillName),
            timestamp: timestamp
        )
    }

    // =========================================================================
    // MARK: - Streaming Event Transformation
    // =========================================================================

    /// Transform a streaming WebSocket event to a ChatMessage.
    ///
    /// Streaming events are used for real-time UI updates during agent execution.
    /// Not all streaming events produce messages - some are control signals.
    ///
    /// - Parameters:
    ///   - type: The streaming event type string (e.g., "agent.tool_start")
    ///   - data: The event data dictionary
    /// - Returns: ChatMessage if this event should be displayed, nil otherwise
    static func transformStreamingEvent(
        type: String,
        data: [String: Any]
    ) -> ChatMessage? {
        guard let eventType = StreamingEventType(rawValue: type) else {
            logger.warning("Unknown streaming event type: \(type)", category: .events)
            return nil
        }

        let timestamp = Date()

        switch eventType {
        case .agentToolStart:
            return transformStreamingToolStart(data, timestamp: timestamp)

        case .agentToolEnd:
            return transformStreamingToolEnd(data, timestamp: timestamp)

        case .agentError:
            return transformStreamingError(data, timestamp: timestamp)

        // These events don't directly create messages - they update existing ones
        case .agentTextDelta, .agentThinkingDelta:
            return nil  // Handled via accumulation in ChatViewModel

        // These are control signals
        case .agentTurnStart, .agentTurnEnd, .agentComplete:
            return nil  // Handled via state updates in ChatViewModel

        // Session events don't create chat messages
        case .sessionCreated, .sessionEnded, .sessionUpdated, .sessionForked, .sessionRewound:
            return nil

        // Sync events are handled separately
        case .eventsNew, .eventsBatch:
            return nil

        // Tree events don't create chat messages
        case .treeUpdated, .treeBranchCreated:
            return nil

        // System events don't create chat messages
        case .systemConnected, .systemDisconnected, .systemError:
            return nil
        }
    }

    // =========================================================================
    // MARK: - Streaming Event Handlers
    // =========================================================================

    private static func transformStreamingToolStart(
        _ data: [String: Any],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = StreamingToolStartPayload(from: data) else { return nil }

        return ChatMessage(
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: parsed.toolName,
                toolCallId: parsed.toolCallId,
                arguments: parsed.arguments,
                status: .running
            )),
            timestamp: timestamp
        )
    }

    private static func transformStreamingToolEnd(
        _ data: [String: Any],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = StreamingToolEndPayload(from: data) else { return nil }

        // Tool end creates a tool result message
        return ChatMessage(
            role: .toolResult,
            content: .toolResult(ToolResultData(
                toolCallId: parsed.toolCallId,
                content: parsed.output ?? parsed.error ?? "",
                isError: !parsed.success,
                toolName: parsed.toolName,
                arguments: nil,
                durationMs: parsed.durationMs
            )),
            timestamp: timestamp
        )
    }

    private static func transformStreamingError(
        _ data: [String: Any],
        timestamp: Date
    ) -> ChatMessage? {
        guard let parsed = StreamingErrorPayload(from: data) else { return nil }

        let errorText = parsed.code != nil
            ? "[\(parsed.code!)] \(parsed.message)"
            : parsed.message

        return ChatMessage(
            role: .assistant,
            content: .error(errorText),
            timestamp: timestamp
        )
    }

    // =========================================================================
    // MARK: - Streaming State Updates
    // =========================================================================

    /// Information extracted from streaming events for UI state updates.
    /// Used by ChatViewModel to update accumulated text, token counts, etc.
    struct StreamingStateUpdate {
        enum UpdateType {
            case textDelta(delta: String, accumulated: String?)
            case thinkingDelta(delta: String)
            case turnStart(turn: Int)
            case turnEnd(turn: Int, tokenUsage: TokenUsage?, stopReason: String?)
            case complete(turns: Int, tokenUsage: TokenUsage?, success: Bool, error: String?)
            case toolStatusUpdate(toolCallId: String, status: ToolStatus, result: String?, durationMs: Int?)
        }

        let type: UpdateType
    }

    /// Extract state update information from a streaming event.
    ///
    /// This is used by ChatViewModel to update UI state without creating
    /// new messages (e.g., accumulating text deltas, updating token counts).
    ///
    /// - Parameters:
    ///   - type: The streaming event type string
    ///   - data: The event data dictionary
    /// - Returns: State update if applicable, nil otherwise
    static func extractStreamingStateUpdate(
        type: String,
        data: [String: Any]
    ) -> StreamingStateUpdate? {
        guard let eventType = StreamingEventType(rawValue: type) else { return nil }

        switch eventType {
        case .agentTextDelta:
            guard let parsed = StreamingTextDeltaPayload(from: data) else { return nil }
            return StreamingStateUpdate(type: .textDelta(
                delta: parsed.delta,
                accumulated: parsed.accumulated
            ))

        case .agentThinkingDelta:
            guard let parsed = StreamingThinkingDeltaPayload(from: data) else { return nil }
            return StreamingStateUpdate(type: .thinkingDelta(delta: parsed.delta))

        case .agentTurnStart:
            guard let parsed = StreamingTurnStartPayload(from: data) else { return nil }
            return StreamingStateUpdate(type: .turnStart(turn: parsed.turn))

        case .agentTurnEnd:
            guard let parsed = StreamingTurnEndPayload(from: data) else { return nil }
            return StreamingStateUpdate(type: .turnEnd(
                turn: parsed.turn,
                tokenUsage: parsed.tokenUsage,
                stopReason: parsed.stopReason
            ))

        case .agentComplete:
            guard let parsed = StreamingCompletePayload(from: data) else { return nil }
            return StreamingStateUpdate(type: .complete(
                turns: parsed.turns,
                tokenUsage: parsed.tokenUsage,
                success: parsed.success,
                error: parsed.error
            ))

        case .agentToolEnd:
            guard let parsed = StreamingToolEndPayload(from: data) else { return nil }
            return StreamingStateUpdate(type: .toolStatusUpdate(
                toolCallId: parsed.toolCallId,
                status: parsed.success ? .success : .error,
                result: parsed.output ?? parsed.error,
                durationMs: parsed.durationMs
            ))

        default:
            return nil
        }
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================

    /// Sort events by timestamp (generation time), then by turn, then by sequence.
    ///
    /// This preserves the streaming order where events are recorded as they occur
    /// during Claude's response generation.
    private static func sortEventsByTurn(_ events: [RawEvent]) -> [RawEvent] {
        events.sorted { a, b in
            // Primary sort: by timestamp (reflects actual generation/streaming order)
            let tsA = parseTimestamp(a.timestamp)
            let tsB = parseTimestamp(b.timestamp)
            if tsA != tsB {
                return tsA < tsB
            }

            // Secondary sort: by turn number from payload
            let turnA = extractTurn(from: a.type, payload: a.payload)
            let turnB = extractTurn(from: b.type, payload: b.payload)
            if turnA != turnB {
                return turnA < turnB
            }

            // Tertiary sort: by sequence
            return a.sequence < b.sequence
        }
    }

    /// Sort SessionEvents by timestamp (generation time), then by turn, then by sequence.
    private static func sortEventsByTurn(_ events: [SessionEvent]) -> [SessionEvent] {
        events.sorted { a, b in
            // Primary sort: by timestamp (reflects actual generation/streaming order)
            let tsA = parseTimestamp(a.timestamp)
            let tsB = parseTimestamp(b.timestamp)
            if tsA != tsB {
                return tsA < tsB
            }

            // Secondary sort: by turn number from payload
            let turnA = extractTurn(from: a.type, payload: a.payload)
            let turnB = extractTurn(from: b.type, payload: b.payload)
            if turnA != turnB {
                return turnA < turnB
            }

            // Tertiary sort: by sequence
            return a.sequence < b.sequence
        }
    }

    /// Extract turn number from event payload based on event type.
    private static func extractTurn(from type: String, payload: [String: AnyCodable]) -> Int {
        // User messages, assistant messages, and tool calls have turn in payload
        if type == PersistedEventType.messageUser.rawValue ||
           type == PersistedEventType.messageAssistant.rawValue ||
           type == PersistedEventType.toolCall.rawValue {
            return payload["turn"]?.value as? Int ?? 0
        }

        // Tool results are linked to tool calls via toolCallId, use sequence-based ordering
        // Other events don't have turns, use 0 to sort them early
        return 0
    }

    private static func parseTimestamp(_ isoString: String) -> Date {
        // Try with fractional seconds first (server events)
        let formatterWithFractions = ISO8601DateFormatter()
        formatterWithFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractions.date(from: isoString) {
            return date
        }

        // Fallback to standard format without fractional seconds (test data)
        let formatterStandard = ISO8601DateFormatter()
        formatterStandard.formatOptions = [.withInternetDateTime]
        return formatterStandard.date(from: isoString) ?? Date()
    }
}

// =============================================================================
// MARK: - Session State Reconstruction
// =============================================================================

extension UnifiedEventTransformer {

    /// Reconstructed session state from event history.
    ///
    /// This structure contains all information needed to display a session,
    /// including messages, token usage, and model info.
    struct ReconstructedState {
        var messages: [ChatMessage]
        var totalTokenUsage: TokenUsage
        var currentModel: String?
        var currentTurn: Int
        var workingDirectory: String?
        /// Current reasoning level for extended thinking models
        var reasoningLevel: String?

        // Extended state (Phase 2)
        var fileActivity: FileActivityState
        var worktree: WorktreeState
        var compaction: CompactionState
        var metadata: MetadataState
        var sessionInfo: SessionInfo
        var tags: [String]

        // MARK: - Nested Types

        /// File read/write/edit activity during the session
        struct FileActivityState {
            var reads: [FileRead]
            var writes: [FileWrite]
            var edits: [FileEdit]

            struct FileRead {
                let path: String
                let timestamp: Date
                let linesStart: Int?
                let linesEnd: Int?
            }

            struct FileWrite {
                let path: String
                let timestamp: Date
                let size: Int
                let contentHash: String
            }

            struct FileEdit {
                let path: String
                let timestamp: Date
                let oldString: String
                let newString: String
                let diff: String?
            }

            init() {
                self.reads = []
                self.writes = []
                self.edits = []
            }

            /// All modified files (writes + edits)
            var modifiedFiles: [String] {
                let writeFiles = writes.map(\.path)
                let editFiles = edits.map(\.path)
                return Array(Set(writeFiles + editFiles))
            }

            /// All touched files (reads + writes + edits)
            var touchedFiles: [String] {
                let readFiles = reads.map(\.path)
                return Array(Set(readFiles + modifiedFiles))
            }
        }

        /// Git worktree activity during the session
        struct WorktreeState {
            var isAcquired: Bool
            var currentWorktree: String?
            var commits: [Commit]
            var merges: [Merge]

            struct Commit {
                let hash: String
                let message: String
                let timestamp: Date
            }

            struct Merge {
                let branch: String
                let timestamp: Date
            }

            init() {
                self.isAcquired = false
                self.currentWorktree = nil
                self.commits = []
                self.merges = []
            }
        }

        /// Context compaction state
        struct CompactionState {
            var boundaries: [Boundary]
            var summaries: [Summary]

            struct Boundary {
                let rangeFrom: String
                let rangeTo: String
                let originalTokens: Int
                let compactedTokens: Int
                let timestamp: Date
            }

            struct Summary {
                let summary: String
                let boundaryEventId: String
                let keyDecisions: [String]?
                let filesModified: [String]?
                let timestamp: Date
            }

            init() {
                self.boundaries = []
                self.summaries = []
            }

            /// Total compactions applied
            var compactionCount: Int { boundaries.count }

            /// Total tokens saved through compaction
            var tokensSaved: Int {
                boundaries.reduce(0) { $0 + ($1.originalTokens - $1.compactedTokens) }
            }
        }

        /// Session metadata
        struct MetadataState {
            var customData: [String: Any]
            var lastUpdated: Date?

            init() {
                self.customData = [:]
                self.lastUpdated = nil
            }
        }

        /// Session start information
        struct SessionInfo {
            var startTime: Date?
            var endTime: Date?
            var initialModel: String?
            var branchName: String?
            var forkSource: String?

            init() {
                self.startTime = nil
                self.endTime = nil
                self.initialModel = nil
                self.branchName = nil
                self.forkSource = nil
            }

            var isActive: Bool { startTime != nil && endTime == nil }
            var duration: TimeInterval? {
                guard let start = startTime else { return nil }
                let end = endTime ?? Date()
                return end.timeIntervalSince(start)
            }
        }

        init() {
            self.messages = []
            self.totalTokenUsage = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: nil, cacheCreationTokens: nil)
            self.currentModel = nil
            self.currentTurn = 0
            self.workingDirectory = nil
            self.reasoningLevel = nil
            self.fileActivity = FileActivityState()
            self.worktree = WorktreeState()
            self.compaction = CompactionState()
            self.metadata = MetadataState()
            self.sessionInfo = SessionInfo()
            self.tags = []
        }
    }

    /// Reconstruct full session state from persisted events.
    ///
    /// This processes all events in order, extracting:
    /// - Chat messages for display
    /// - Accumulated token usage
    /// - Current model (after any switches)
    /// - Working directory
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: All events for the session
    /// - Returns: Fully reconstructed session state
    static func reconstructSessionState(from events: [RawEvent]) -> ReconstructedState {
        var state = ReconstructedState()

        // Sort by turn number, then timestamp, then sequence
        let sorted = sortEventsByTurn(events)

        // PASS 1: Collect deleted event IDs, config state, and build tool maps
        // Two-pass reconstruction ensures deletions that occur later are properly filtered
        var deletedEventIds = Set<String>()
        var toolCalls: [String: ToolCallPayload] = [:]
        var toolResults: [String: ToolResultPayload] = [:]

        for event in sorted {
            if event.type == PersistedEventType.toolCall.rawValue,
               let payload = ToolCallPayload(from: event.payload) {
                toolCalls[payload.toolCallId] = payload
            }
            if event.type == PersistedEventType.toolResult.rawValue,
               let payload = ToolResultPayload(from: event.payload) {
                toolResults[payload.toolCallId] = payload
            }
            // Collect deleted event IDs
            if event.type == PersistedEventType.messageDeleted.rawValue,
               let payload = MessageDeletedPayload(from: event.payload) {
                deletedEventIds.insert(payload.targetEventId)
            }
            // Track latest reasoning level
            if event.type == PersistedEventType.configReasoningLevel.rawValue {
                let payload = ReasoningLevelPayload(from: event.payload)
                state.reasoningLevel = payload.newLevel
            }
        }

        // PASS 2: Build messages, skipping deleted ones
        for event in sorted {
            // Skip deleted events
            if deletedEventIds.contains(event.id) {
                continue
            }
            guard let eventType = PersistedEventType(rawValue: event.type) else { continue }

            switch eventType {
            case .sessionStart:
                let payload = SessionStartPayload(from: event.payload)
                state.currentModel = payload.model
                state.workingDirectory = payload.workingDirectory
                state.sessionInfo.startTime = parseTimestamp(event.timestamp)
                state.sessionInfo.initialModel = payload.model

            case .toolResult, .toolCall:
                // Skip - tool calls are processed via message.assistant content blocks
                break

            case .messageAssistant:
                // Process content blocks in order (preserves interleaving)
                var interleaved = transformAssistantMessageInterleaved(
                    event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults
                )
                // Set eventId on the first message for deletion tracking
                // (interleaved may produce multiple messages from one event)
                if !interleaved.isEmpty {
                    interleaved[0].eventId = event.id
                }
                state.messages.append(contentsOf: interleaved)

                // Track token usage from assistant messages
                // Input tokens: use LAST turn's value (represents current context size)
                // Output tokens: ACCUMULATE (total generated content)
                let payload = AssistantMessagePayload(from: event.payload)
                if let usage = payload.tokenUsage {
                    state.totalTokenUsage = TokenUsage(
                        inputTokens: usage.inputTokens,  // Current context, not accumulated
                        outputTokens: state.totalTokenUsage.outputTokens + usage.outputTokens,
                        cacheReadTokens: (state.totalTokenUsage.cacheReadTokens ?? 0) + (usage.cacheReadTokens ?? 0),
                        cacheCreationTokens: (state.totalTokenUsage.cacheCreationTokens ?? 0) + (usage.cacheCreationTokens ?? 0)
                    )
                }
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            case .messageUser, .messageSystem,
                 .notificationInterrupted, .configModelSwitch, .configReasoningLevel,
                 .contextCleared, .skillRemoved,
                 .errorAgent, .errorTool, .errorProvider:
                // Add chat message
                if var message = transformPersistedEvent(event) {
                    // Set eventId for message deletion tracking (user messages only)
                    if eventType == .messageUser {
                        message.eventId = event.id
                    }
                    state.messages.append(message)
                }

                // Track model switches
                if eventType == .configModelSwitch,
                   let parsed = ModelSwitchPayload(from: event.payload) {
                    state.currentModel = parsed.newModel
                }

                // Track reasoning level changes (state already updated in pass 1)
                // The chat message is created above via transformPersistedEvent

            case .streamTurnEnd:
                // Only update turn counter, NOT token usage
                // Token usage is already captured in message.assistant events
                // Accumulating here would double-count tokens
                let payload = StreamTurnEndPayload(from: event.payload)
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            // MARK: - Extended State Events (Phase 2)

            case .sessionEnd:
                state.sessionInfo.endTime = parseTimestamp(event.timestamp)

            case .sessionFork:
                if let source = event.payload["sourceEventId"]?.value as? String {
                    state.sessionInfo.forkSource = source
                }

            case .sessionBranch:
                if let parsed = SessionBranchPayload(from: event.payload) {
                    state.sessionInfo.branchName = parsed.name
                }

            case .fileRead:
                if let parsed = FileReadPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.reads.append(ReconstructedState.FileActivityState.FileRead(
                        path: parsed.path,
                        timestamp: ts,
                        linesStart: parsed.linesStart,
                        linesEnd: parsed.linesEnd
                    ))
                }

            case .fileWrite:
                if let parsed = FileWritePayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.writes.append(ReconstructedState.FileActivityState.FileWrite(
                        path: parsed.path,
                        timestamp: ts,
                        size: parsed.size,
                        contentHash: parsed.contentHash
                    ))
                }

            case .fileEdit:
                if let parsed = FileEditPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.edits.append(ReconstructedState.FileActivityState.FileEdit(
                        path: parsed.path,
                        timestamp: ts,
                        oldString: parsed.oldString,
                        newString: parsed.newString,
                        diff: parsed.diff
                    ))
                }

            case .worktreeAcquired:
                state.worktree.isAcquired = true
                if let path = event.payload["path"]?.value as? String {
                    state.worktree.currentWorktree = path
                }

            case .worktreeReleased:
                state.worktree.isAcquired = false

            case .worktreeCommit:
                let ts = parseTimestamp(event.timestamp)
                let hash = event.payload["hash"]?.value as? String ?? ""
                let message = event.payload["message"]?.value as? String ?? ""
                state.worktree.commits.append(ReconstructedState.WorktreeState.Commit(
                    hash: hash,
                    message: message,
                    timestamp: ts
                ))

            case .worktreeMerged:
                let ts = parseTimestamp(event.timestamp)
                let branch = event.payload["branch"]?.value as? String ?? ""
                state.worktree.merges.append(ReconstructedState.WorktreeState.Merge(
                    branch: branch,
                    timestamp: ts
                ))

            case .compactBoundary:
                if let parsed = CompactBoundaryPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.compaction.boundaries.append(ReconstructedState.CompactionState.Boundary(
                        rangeFrom: parsed.rangeFrom,
                        rangeTo: parsed.rangeTo,
                        originalTokens: parsed.originalTokens,
                        compactedTokens: parsed.compactedTokens,
                        timestamp: ts
                    ))
                }

            case .compactSummary:
                if let parsed = CompactSummaryPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.compaction.summaries.append(ReconstructedState.CompactionState.Summary(
                        summary: parsed.summary,
                        boundaryEventId: parsed.boundaryEventId,
                        keyDecisions: parsed.keyDecisions,
                        filesModified: parsed.filesModified,
                        timestamp: ts
                    ))
                }

            case .metadataUpdate:
                if let parsed = MetadataUpdatePayload(from: event.payload) {
                    state.metadata.customData[parsed.key] = parsed.newValue
                    state.metadata.lastUpdated = parseTimestamp(event.timestamp)
                }

            case .metadataTag:
                if let parsed = MetadataTagPayload(from: event.payload) {
                    if parsed.action == "add" && !state.tags.contains(parsed.tag) {
                        state.tags.append(parsed.tag)
                    } else if parsed.action == "remove" {
                        state.tags.removeAll { $0 == parsed.tag }
                    }
                }

            // Other event types are skipped for state reconstruction
            // Note: configReasoningLevel and messageDeleted are already processed in pass 1
            default:
                break
            }
        }

        return state
    }

    /// Reconstruct full session state from SessionEvents (from EventDatabase).
    ///
    /// Overload that accepts SessionEvent from the local SQLite database.
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: SessionEvents from EventDatabase (should be from getAncestors)
    /// - Returns: Fully reconstructed session state
    static func reconstructSessionState(from events: [SessionEvent]) -> ReconstructedState {
        var state = ReconstructedState()

        // Sort by turn number, then timestamp, then sequence
        let sorted = sortEventsByTurn(events)

        // PASS 1: Collect deleted event IDs, config state, and build tool maps
        // Two-pass reconstruction ensures deletions that occur later are properly filtered
        var deletedEventIds = Set<String>()
        var toolCalls: [String: ToolCallPayload] = [:]
        var toolResults: [String: ToolResultPayload] = [:]

        for event in sorted {
            if event.type == PersistedEventType.toolCall.rawValue,
               let payload = ToolCallPayload(from: event.payload) {
                toolCalls[payload.toolCallId] = payload
            }
            if event.type == PersistedEventType.toolResult.rawValue,
               let payload = ToolResultPayload(from: event.payload) {
                toolResults[payload.toolCallId] = payload
            }
            // Collect deleted event IDs
            if event.type == PersistedEventType.messageDeleted.rawValue,
               let payload = MessageDeletedPayload(from: event.payload) {
                deletedEventIds.insert(payload.targetEventId)
            }
            // Track latest reasoning level
            if event.type == PersistedEventType.configReasoningLevel.rawValue {
                let payload = ReasoningLevelPayload(from: event.payload)
                state.reasoningLevel = payload.newLevel
            }
        }

        // PASS 2: Build messages, skipping deleted ones
        for event in sorted {
            // Skip deleted events
            if deletedEventIds.contains(event.id) {
                continue
            }
            guard let eventType = PersistedEventType(rawValue: event.type) else { continue }

            switch eventType {
            case .sessionStart:
                let payload = SessionStartPayload(from: event.payload)
                state.currentModel = payload.model
                state.workingDirectory = payload.workingDirectory
                state.sessionInfo.startTime = parseTimestamp(event.timestamp)
                state.sessionInfo.initialModel = payload.model

            case .toolResult, .toolCall:
                // Skip - tool calls are processed via message.assistant content blocks
                break

            case .messageAssistant:
                // Process content blocks in order (preserves interleaving)
                var interleaved = transformAssistantMessageInterleaved(
                    event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults
                )
                // Set eventId on the first message for deletion tracking
                // (interleaved may produce multiple messages from one event)
                if !interleaved.isEmpty {
                    interleaved[0].eventId = event.id
                }
                state.messages.append(contentsOf: interleaved)

                // Track token usage from assistant messages
                // Input tokens: use LAST turn's value (represents current context size)
                // Output tokens: ACCUMULATE (total generated content)
                let payload = AssistantMessagePayload(from: event.payload)
                if let usage = payload.tokenUsage {
                    state.totalTokenUsage = TokenUsage(
                        inputTokens: usage.inputTokens,  // Current context, not accumulated
                        outputTokens: state.totalTokenUsage.outputTokens + usage.outputTokens,
                        cacheReadTokens: (state.totalTokenUsage.cacheReadTokens ?? 0) + (usage.cacheReadTokens ?? 0),
                        cacheCreationTokens: (state.totalTokenUsage.cacheCreationTokens ?? 0) + (usage.cacheCreationTokens ?? 0)
                    )
                }
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            case .messageUser, .messageSystem,
                 .notificationInterrupted, .configModelSwitch, .configReasoningLevel,
                 .contextCleared, .skillRemoved,
                 .errorAgent, .errorTool, .errorProvider:
                // Add chat message using the SessionEvent overload
                if var message = transformPersistedEvent(event) {
                    // Set eventId for message deletion tracking (user messages only)
                    if eventType == .messageUser {
                        message.eventId = event.id
                    }
                    state.messages.append(message)
                }

                // Track model switches
                if eventType == .configModelSwitch,
                   let parsed = ModelSwitchPayload(from: event.payload) {
                    state.currentModel = parsed.newModel
                }

                // Track reasoning level changes (state already updated in pass 1)
                // The chat message is created above via transformPersistedEvent

            case .streamTurnEnd:
                // Only update turn counter, NOT token usage
                // Token usage is already captured in message.assistant events
                // Accumulating here would double-count tokens
                let payload = StreamTurnEndPayload(from: event.payload)
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            // MARK: - Extended State Events (Phase 2)

            case .sessionEnd:
                state.sessionInfo.endTime = parseTimestamp(event.timestamp)

            case .sessionFork:
                if let source = event.payload["sourceEventId"]?.value as? String {
                    state.sessionInfo.forkSource = source
                }

            case .sessionBranch:
                if let parsed = SessionBranchPayload(from: event.payload) {
                    state.sessionInfo.branchName = parsed.name
                }

            case .fileRead:
                if let parsed = FileReadPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.reads.append(ReconstructedState.FileActivityState.FileRead(
                        path: parsed.path,
                        timestamp: ts,
                        linesStart: parsed.linesStart,
                        linesEnd: parsed.linesEnd
                    ))
                }

            case .fileWrite:
                if let parsed = FileWritePayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.writes.append(ReconstructedState.FileActivityState.FileWrite(
                        path: parsed.path,
                        timestamp: ts,
                        size: parsed.size,
                        contentHash: parsed.contentHash
                    ))
                }

            case .fileEdit:
                if let parsed = FileEditPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.fileActivity.edits.append(ReconstructedState.FileActivityState.FileEdit(
                        path: parsed.path,
                        timestamp: ts,
                        oldString: parsed.oldString,
                        newString: parsed.newString,
                        diff: parsed.diff
                    ))
                }

            case .worktreeAcquired:
                state.worktree.isAcquired = true
                if let path = event.payload["path"]?.value as? String {
                    state.worktree.currentWorktree = path
                }

            case .worktreeReleased:
                state.worktree.isAcquired = false

            case .worktreeCommit:
                let ts = parseTimestamp(event.timestamp)
                let hash = event.payload["hash"]?.value as? String ?? ""
                let message = event.payload["message"]?.value as? String ?? ""
                state.worktree.commits.append(ReconstructedState.WorktreeState.Commit(
                    hash: hash,
                    message: message,
                    timestamp: ts
                ))

            case .worktreeMerged:
                let ts = parseTimestamp(event.timestamp)
                let branch = event.payload["branch"]?.value as? String ?? ""
                state.worktree.merges.append(ReconstructedState.WorktreeState.Merge(
                    branch: branch,
                    timestamp: ts
                ))

            case .compactBoundary:
                if let parsed = CompactBoundaryPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.compaction.boundaries.append(ReconstructedState.CompactionState.Boundary(
                        rangeFrom: parsed.rangeFrom,
                        rangeTo: parsed.rangeTo,
                        originalTokens: parsed.originalTokens,
                        compactedTokens: parsed.compactedTokens,
                        timestamp: ts
                    ))
                }

            case .compactSummary:
                if let parsed = CompactSummaryPayload(from: event.payload) {
                    let ts = parseTimestamp(event.timestamp)
                    state.compaction.summaries.append(ReconstructedState.CompactionState.Summary(
                        summary: parsed.summary,
                        boundaryEventId: parsed.boundaryEventId,
                        keyDecisions: parsed.keyDecisions,
                        filesModified: parsed.filesModified,
                        timestamp: ts
                    ))
                }

            case .metadataUpdate:
                if let parsed = MetadataUpdatePayload(from: event.payload) {
                    state.metadata.customData[parsed.key] = parsed.newValue
                    state.metadata.lastUpdated = parseTimestamp(event.timestamp)
                }

            case .metadataTag:
                if let parsed = MetadataTagPayload(from: event.payload) {
                    if parsed.action == "add" && !state.tags.contains(parsed.tag) {
                        state.tags.append(parsed.tag)
                    } else if parsed.action == "remove" {
                        state.tags.removeAll { $0 == parsed.tag }
                    }
                }

            // Other event types are skipped for state reconstruction
            // Note: configReasoningLevel and messageDeleted are already processed in pass 1
            default:
                break
            }
        }

        return state
    }
}
