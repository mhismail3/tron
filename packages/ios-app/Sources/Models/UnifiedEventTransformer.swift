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
    /// This generic implementation works with any `EventTransformable` type,
    /// including `RawEvent` (from server RPC) and `SessionEvent` (from SQLite).
    ///
    /// Events are sorted by sequence number, then turn number within each turn
    /// (text before tools) to preserve the logical order of Claude's responses.
    ///
    /// **Important**: Tool calls (`tool.call`) are combined with their results
    /// (`tool.result`) into a single message. This matches the streaming UI
    /// behavior where tool calls show their results inline.
    ///
    /// - Parameter events: Events conforming to EventTransformable
    /// - Returns: Array of ChatMessages in chronological order
    static func transformPersistedEvents<E: EventTransformable>(_ events: [E]) -> [ChatMessage] {
        // Sort by turn number, then timestamp, then sequence
        let sorted = EventSorter.sortBySequence(events)

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
                let interleaved = InterleavedContentProcessor.transform(
                    payload: event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults,
                    allEvents: sorted  // Pass sorted events for AskUserQuestion status detection
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

    /// Transform a single event to a ChatMessage.
    ///
    /// This generic implementation works with any `EventTransformable` type.
    ///
    /// - Parameter event: An event conforming to EventTransformable
    /// - Returns: ChatMessage if this event should be displayed, nil otherwise
    static func transformPersistedEvent<E: EventTransformable>(_ event: E) -> ChatMessage? {
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
            return MessageHandlers.transformUserMessage(payload, timestamp: ts)
        case .messageAssistant:
            return MessageHandlers.transformAssistantMessage(payload, timestamp: ts)
        case .messageSystem:
            return MessageHandlers.transformSystemMessage(payload, timestamp: ts)
        case .toolCall:
            return ToolHandlers.transformToolCall(payload, timestamp: ts)
        case .toolResult:
            return ToolHandlers.transformToolResult(payload, timestamp: ts)
        case .notificationInterrupted:
            return SystemEventHandlers.transformInterrupted(payload, timestamp: ts)
        case .notificationSubagentResult:
            return SystemEventHandlers.transformSubagentResultNotification(payload, timestamp: ts)
        case .configModelSwitch:
            return ConfigHandlers.transformModelSwitch(payload, timestamp: ts)
        case .configReasoningLevel:
            return ConfigHandlers.transformReasoningLevelChange(payload, timestamp: ts)
        case .errorAgent:
            return ErrorHandlers.transformAgentError(payload, timestamp: ts)
        case .errorTool:
            return ErrorHandlers.transformToolError(payload, timestamp: ts)
        case .errorProvider:
            return ErrorHandlers.transformProviderError(payload, timestamp: ts)
        case .turnFailed:
            return ErrorHandlers.transformTurnFailed(payload, timestamp: ts)
        case .contextCleared:
            return SystemEventHandlers.transformContextCleared(payload, timestamp: ts)
        case .memoryLedger:
            return SystemEventHandlers.transformMemoryLedger(payload, timestamp: ts)
        case .compactBoundary:
            return SystemEventHandlers.transformCompactBoundary(payload, timestamp: ts)
        case .skillRemoved:
            return SystemEventHandlers.transformSkillRemoved(payload, timestamp: ts)
        case .rulesLoaded:
            return SystemEventHandlers.transformRulesLoaded(payload, timestamp: ts)
        case .streamThinkingComplete:
            return SystemEventHandlers.transformThinkingComplete(payload, timestamp: ts)
        default:
            return nil
        }
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================


    /// Extract preview (first 3 lines) from thinking content for display
    private static func extractThinkingPreview(from content: String, maxLines: Int = 3) -> String {
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(maxLines)
        let preview = lines.joined(separator: " ")
        if preview.count > 120 {
            return String(preview.prefix(117)) + "..."
        }
        return preview
    }

    /// Parse ISO 8601 timestamp string to Date.
    /// Delegates to EventSorter for the implementation.
    private static func parseTimestamp(_ isoString: String) -> Date {
        EventSorter.parseTimestamp(isoString)
    }
}

// =============================================================================
// MARK: - Session State Reconstruction
// =============================================================================

extension UnifiedEventTransformer {

    /// Reconstruct full session state from persisted events.
    ///
    /// This generic implementation works with any `EventTransformable` type,
    /// processing all events in order to extract:
    /// - Chat messages for display
    /// - Accumulated token usage
    /// - Current model (after any switches)
    /// - Working directory
    /// - Extended state (file activity, worktree, compaction, etc.)
    ///
    /// **Two-Pass Reconstruction**:
    /// - Pass 1: Collect deleted event IDs, tool maps, and config state
    /// - Pass 2: Build messages while filtering deleted events
    ///
    /// **AskUserQuestion Status Detection**:
    /// Events are passed to `InterleavedContentProcessor` to enable proper
    /// status detection (pending/answered/superseded) by examining subsequent
    /// user messages.
    ///
    /// - Parameters:
    ///   - events: Events conforming to EventTransformable (RawEvent or SessionEvent)
    ///   - presorted: If true, events are already in correct chain order from getAncestors
    ///                and should NOT be re-sorted. This is critical for forked sessions
    ///                where sequence numbers reset and sorting by sequence would interleave
    ///                parent and forked session events incorrectly.
    /// - Returns: Fully reconstructed session state
    static func reconstructSessionState<E: EventTransformable>(from events: [E], presorted: Bool = false) -> ReconstructedState {
        var state = ReconstructedState()

        // Only sort if events are not pre-sorted (from getAncestors)
        // For forked sessions, sequence numbers reset per-session, so sorting by sequence
        // would incorrectly interleave parent and forked events
        let sorted = presorted ? events : EventSorter.sortBySequence(events)

        // PASS 1: Collect deleted event IDs, config state, and tool maps
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
            if event.type == PersistedEventType.messageDeleted.rawValue,
               let payload = MessageDeletedPayload(from: event.payload) {
                deletedEventIds.insert(payload.targetEventId)
            }
            if event.type == PersistedEventType.configReasoningLevel.rawValue {
                let payload = ReasoningLevelPayload(from: event.payload)
                state.reasoningLevel = payload.newLevel
            }
        }

        // PASS 2: Build messages, skipping deleted ones
        for event in sorted {
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
                // Skip - processed via message.assistant content blocks
                break

            case .messageAssistant:
                var interleaved = InterleavedContentProcessor.transform(
                    payload: event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    toolCalls: toolCalls,
                    toolResults: toolResults,
                    allEvents: sorted  // Pass events for AskUserQuestion status detection
                )
                if !interleaved.isEmpty {
                    interleaved[0].eventId = event.id
                }
                state.messages.append(contentsOf: interleaved)

                let payload = AssistantMessagePayload(from: event.payload)
                if let record = payload.tokenRecord {
                    state.totalTokenUsage = TokenUsage(
                        inputTokens: state.totalTokenUsage.inputTokens + record.source.rawInputTokens,
                        outputTokens: state.totalTokenUsage.outputTokens + record.source.rawOutputTokens,
                        cacheReadTokens: (state.totalTokenUsage.cacheReadTokens ?? 0) + record.source.rawCacheReadTokens,
                        cacheCreationTokens: (state.totalTokenUsage.cacheCreationTokens ?? 0) + record.source.rawCacheCreationTokens
                    )
                    state.lastTurnInputTokens = record.computed.contextWindowTokens
                }
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            case .messageUser, .messageSystem,
                 .notificationInterrupted, .notificationSubagentResult,
                 .configModelSwitch, .configReasoningLevel,
                 .contextCleared, .memoryLedger, .skillRemoved, .rulesLoaded,
                 .errorAgent, .errorTool, .errorProvider,
                 .streamThinkingComplete:
                if var message = transformPersistedEvent(event) {
                    if eventType == .messageUser {
                        message.eventId = event.id
                    }
                    state.messages.append(message)
                }
                if eventType == .configModelSwitch,
                   let parsed = ModelSwitchPayload(from: event.payload) {
                    state.currentModel = parsed.newModel
                }
                // Extract subagent result info for SubagentState reconstruction
                if eventType == .notificationSubagentResult,
                   let sessionId = event.payload["subagentSessionId"]?.value as? String {
                    let info = ReconstructedState.SubagentResultInfo(
                        subagentSessionId: sessionId,
                        task: event.payload["task"]?.value as? String ?? "",
                        resultSummary: event.payload["resultSummary"]?.value as? String ?? "",
                        success: event.payload["success"]?.value as? Bool ?? true,
                        totalTurns: event.payload["totalTurns"]?.value as? Int ?? 0,
                        duration: event.payload["duration"]?.value as? Int,
                        tokenUsage: nil
                    )
                    state.subagentResults.append(info)
                }

            case .streamTurnEnd:
                let payload = StreamTurnEndPayload(from: event.payload)
                if payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

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
                    state.fileActivity.reads.append(ReconstructedState.FileActivityState.FileRead(
                        path: parsed.path,
                        timestamp: parseTimestamp(event.timestamp),
                        linesStart: parsed.linesStart,
                        linesEnd: parsed.linesEnd
                    ))
                }

            case .fileWrite:
                if let parsed = FileWritePayload(from: event.payload) {
                    state.fileActivity.writes.append(ReconstructedState.FileActivityState.FileWrite(
                        path: parsed.path,
                        timestamp: parseTimestamp(event.timestamp),
                        size: parsed.size,
                        contentHash: parsed.contentHash
                    ))
                }

            case .fileEdit:
                if let parsed = FileEditPayload(from: event.payload) {
                    state.fileActivity.edits.append(ReconstructedState.FileActivityState.FileEdit(
                        path: parsed.path,
                        timestamp: parseTimestamp(event.timestamp),
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
                state.worktree.commits.append(ReconstructedState.WorktreeState.Commit(
                    hash: event.payload["hash"]?.value as? String ?? "",
                    message: event.payload["message"]?.value as? String ?? "",
                    timestamp: parseTimestamp(event.timestamp)
                ))

            case .worktreeMerged:
                state.worktree.merges.append(ReconstructedState.WorktreeState.Merge(
                    branch: event.payload["branch"]?.value as? String ?? "",
                    timestamp: parseTimestamp(event.timestamp)
                ))

            case .compactBoundary:
                if let message = transformPersistedEvent(event) {
                    state.messages.append(message)
                }
                if let parsed = CompactBoundaryPayload(from: event.payload) {
                    state.compaction.boundaries.append(ReconstructedState.CompactionState.Boundary(
                        rangeFrom: parsed.rangeFrom,
                        rangeTo: parsed.rangeTo,
                        originalTokens: parsed.originalTokens,
                        compactedTokens: parsed.compactedTokens,
                        timestamp: parseTimestamp(event.timestamp)
                    ))
                }

            case .compactSummary:
                if let parsed = CompactSummaryPayload(from: event.payload) {
                    state.compaction.summaries.append(ReconstructedState.CompactionState.Summary(
                        summary: parsed.summary,
                        boundaryEventId: parsed.boundaryEventId,
                        keyDecisions: parsed.keyDecisions,
                        filesModified: parsed.filesModified,
                        timestamp: parseTimestamp(event.timestamp)
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

            default:
                break
            }
        }

        return state
    }
}
