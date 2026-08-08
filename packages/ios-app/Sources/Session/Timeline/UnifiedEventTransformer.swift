import Foundation

/// Session-owned transient projection restored from durable event history.
///
/// Server/session metadata remains authoritative for model, turn, workspace,
/// branch, file, and metadata facts. This value carries only the timeline and
/// presentation state that `ChatViewModel` mounts after reconstruction.
struct ReconstructedState {
    var messages: [ChatMessage] = []
    var totalTokenUsage = TokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: nil,
        cacheCreationTokens: nil
    )
    var lastTurnInputTokens = 0
}

// =============================================================================
// MARK: - Unified Event Transformer
// =============================================================================

/// The single source of truth for transforming server events into ChatMessages.
///
/// This transformer handles BOTH:
/// 1. Persisted events (from `session::reconstruct` / SQLite cache)
/// 2. Streaming events (from WebSocket during live agent execution)
///
/// ## Architecture Principle
/// **Content block order is the source of truth for interleaving.**
///
/// The server sends `message.assistant` events with content blocks in exact
/// streaming order via `currentTurnContentSequence`. This preserves the interleaving
/// of text and tool invocations as they appeared during streaming:
///
/// ```
/// [text: "I'll run sleep 3...", tool_invocation: {id: "t1"}, text: "Done!", ...]
/// ```
///
/// Tool details come from separate `tool.invocation.started` events (identity, arguments, turn).
/// Tool results come from `tool.invocation.completed` events. Both are combined when rendering
/// tool_invocation content blocks from the message.assistant.
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
    /// including `RawEvent` (from server engine protocol) and `SessionEvent` (from SQLite).
    ///
    /// Events are sorted by sequence number unless the caller passes a server-
    /// ordered chain. Forked session reconstruction crosses session boundaries,
    /// so sequence numbers can reset and the server's ancestor order is the
    /// chronology contract.
    ///
    /// **Important**: Tool invocations (`tool.invocation.started`) are combined with their results
    /// (`tool.invocation.completed`) into a single message. This matches the streaming UI
    /// behavior where tool invocations show their results inline.
    ///
    /// - Parameters:
    ///   - events: Events conforming to EventTransformable
    ///   - presorted: Whether `events` already arrive in chronological chain order.
    /// - Returns: Array of ChatMessages in chronological order
    static func transformPersistedEvents<E: EventTransformable>(_ events: [E], presorted: Bool = false) -> [ChatMessage] {
        transformPersistedEvents(events, presorted: presorted, toolMaps: nil)
    }

    /// Transform a page of persisted events with additional tool lifecycle
    /// context from already-loaded neighboring pages.
    static func transformPersistedEvents<E: EventTransformable, C: EventTransformable>(
        _ events: [E],
        presorted: Bool = false,
        toolContextEvents: [C]
    ) -> [ChatMessage] {
        var maps = buildToolInvocationMaps(from: events)
        maps.merge(buildToolInvocationMaps(from: toolContextEvents))
        return transformPersistedEvents(events, presorted: presorted, toolMaps: maps)
    }

    private static func transformPersistedEvents<E: EventTransformable>(
        _ events: [E],
        presorted: Bool,
        toolMaps: ToolInvocationMapResult?
    ) -> [ChatMessage] {
        let sorted = presorted ? events : EventSorter.sortBySequence(events)

        // Build maps for tool invocation rendering.
        let maps = toolMaps ?? buildToolInvocationMaps(from: sorted)
        let startedInvocations = maps.startedInvocations
        let completedInvocations = maps.completedInvocations
        let userInputAnswers = maps.userInputAnswers

        TronLogger.shared.debug("[RECONSTRUCT] Built maps: \(startedInvocations.count) tool.invocation.started, \(completedInvocations.count) tool.invocation.completed from \(sorted.count) events", category: .session)

        // Transform events, processing message.assistant content blocks in order
        var messages: [ChatMessage] = []
        for event in sorted {
            // Skip tool.invocation.started, tool.invocation.completed, and stream.thinking_complete —
            // all are processed via message.assistant content blocks
            if event.type == SessionEventType.toolInvocationStarted.rawValue ||
               event.type == SessionEventType.toolInvocationCompleted.rawValue ||
               event.type == SessionEventType.streamThinkingComplete.rawValue {
                continue
            }

            // message.assistant: process content blocks in order (preserves interleaving)
            if event.type == SessionEventType.messageAssistant.rawValue {
                var interleaved = InterleavedContentProcessor.transform(
                    payload: event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    startedInvocations: startedInvocations,
                    completedInvocations: completedInvocations,
                    userInputAnswers: userInputAnswers
                )
                if !interleaved.isEmpty {
                    interleaved[0].eventId = event.id
                }
                messages.append(contentsOf: interleaved)
            } else {
                if var msg = transformPersistedEvent(event) {
                    msg.eventId = event.id
                    messages.append(msg)
                }
            }
        }

        return AgentDeliveryContinuationPresentation.deduplicatingTranscript(
            messages
        )
    }

    /// Transform a single event to a ChatMessage.
    ///
    /// This generic implementation works with any `EventTransformable` type.
    ///
    /// - Parameter event: An event conforming to EventTransformable
    /// - Returns: ChatMessage if this event should be displayed, nil otherwise
    static func transformPersistedEvent<E: EventTransformable>(_ event: E) -> ChatMessage? {
        transformPersistedEvent(type: event.type, timestamp: event.timestamp, payload: event.payload, eventId: event.id)
    }

    /// Internal helper: transform by extracting common fields.
    private static func transformPersistedEvent(
        type: String,
        timestamp: String,
        payload: [String: AnyCodable],
        eventId: String? = nil
    ) -> ChatMessage? {
        guard let eventType = SessionEventType(rawValue: type), eventType != .unknown else {
            logger.warning("Unknown persisted event type: \(type)", category: .events)
            return nil
        }

        let ts = parseTimestamp(timestamp)

        switch eventType {
        case .messageUser:
            return MessageEventProjection.transformUserMessage(payload, timestamp: ts)
        case .messageAssistant:
            return MessageEventProjection.transformAssistantMessage(payload, timestamp: ts)
        case .toolInvocationStarted:
            return ToolInvocationEventProjection.transformInvocationStarted(payload, timestamp: ts)
        case .toolInvocationCompleted:
            return ToolInvocationEventProjection.transformInvocationCompleted(payload, timestamp: ts)
        case .turnFailed:
            return ErrorEventProjection.transformTurnFailed(payload, timestamp: ts)
        case .compactBoundary:
            return SystemEventProjection.transformCompactBoundary(payload, timestamp: ts)
        default:
            return nil
        }
    }

    // =========================================================================
    // MARK: - Tool Invocation Map Collection (shared between transform and reconstruct)
    // =========================================================================

    /// Result of the first-pass collection over events.
    /// Both `transformPersistedEvents` and `reconstructSessionState` need these maps
    /// to resolve provider `tool_invocation` content blocks.
    struct ToolInvocationMapResult {
        var startedInvocations: [String: ToolInvocationStartedPayload] = [:]
        var completedInvocations: [String: ToolInvocationCompletedPayload] = [:]
        var userInputAnswers: [String: [UserInputAnswer]] = [:]

        mutating func merge(_ other: ToolInvocationMapResult) {
            startedInvocations.merge(other.startedInvocations) { current, _ in current }
            completedInvocations.merge(other.completedInvocations) { current, _ in current }
            userInputAnswers.merge(other.userInputAnswers) { current, _ in current }
        }
    }

    /// Single-pass collection of started/completed tool invocations from a sorted event array.
    static func buildToolInvocationMaps<E: EventTransformable>(from events: [E]) -> ToolInvocationMapResult {
        var result = ToolInvocationMapResult()
        for event in events {
            if event.type == SessionEventType.toolInvocationStarted.rawValue,
               let payload = ToolInvocationStartedPayload(from: event.payload) {
                result.startedInvocations[payload.invocationId] = payload
            }
            if event.type == SessionEventType.toolInvocationCompleted.rawValue,
               let payload = ToolInvocationCompletedPayload(from: event.payload) {
                result.completedInvocations[payload.invocationId] = payload
            }
            if event.type == SessionEventType.messageUser.rawValue,
               let payload = UserMessagePayload(from: event.payload),
               let answer = payload.userInputAnswer {
                result.userInputAnswers[answer.invocationId] = answer.answers
            }
        }
        return result
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================

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

    /// Reconstruct the mounted chat projection from persisted events.
    ///
    /// This generic implementation works with any `EventTransformable` type,
    /// processing all events in order to extract:
    /// - Chat messages for display
    /// - The latest reasoning level
    /// - Accumulated token usage
    /// - The latest server-reported context size
    ///
    /// **Two-Pass Reconstruction**:
    /// - Pass 1: Collect deleted event IDs, tool invocation maps, and config state
    /// - Pass 2: Build messages while filtering deleted events
    ///
    /// - Parameters:
    ///   - events: Events conforming to EventTransformable (RawEvent or SessionEvent)
    ///   - presorted: If true, events are already in correct chain order from getAncestors
    ///                and should NOT be re-sorted. This is critical for forked sessions
    ///                where sequence numbers reset and sorting by sequence would interleave
    ///                parent and forked session events incorrectly.
    /// - Returns: The transient timeline/config/token projection mounted by chat
    static func reconstructSessionState<E: EventTransformable>(from events: [E], presorted: Bool = false) -> ReconstructedState {
        var state = ReconstructedState()

        // Only sort if events are not pre-sorted (from getAncestors)
        // For forked sessions, sequence numbers reset per-session, so sorting by sequence
        // would incorrectly interleave parent and forked events
        let sorted = presorted ? events : EventSorter.sortBySequence(events)

        // PASS 1: Collect tool invocation maps and deleted event IDs.
        let maps = buildToolInvocationMaps(from: sorted)
        let startedInvocations = maps.startedInvocations
        let completedInvocations = maps.completedInvocations
        let userInputAnswers = maps.userInputAnswers

        var deletedEventIds = Set<String>()
        for event in sorted {
            if event.type == SessionEventType.messageDeleted.rawValue,
               let payload = MessageDeletedPayload(from: event.payload) {
                deletedEventIds.insert(payload.targetEventId)
            }
        }

        // PASS 2: Build messages, skipping deleted and consumed events
        for event in sorted {
            if deletedEventIds.contains(event.id) {
                continue
            }
            guard let eventType = SessionEventType(rawValue: event.type), eventType != .unknown else { continue }

            switch eventType {
            case .toolInvocationCompleted, .toolInvocationStarted, .streamThinkingComplete:
                // Skip - processed via message.assistant content blocks
                break

            case .messageAssistant:
                var interleaved = InterleavedContentProcessor.transform(
                    payload: event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    startedInvocations: startedInvocations,
                    completedInvocations: completedInvocations,
                    userInputAnswers: userInputAnswers
                )
                if !interleaved.isEmpty {
                    interleaved[0].eventId = event.id
                }
                state.messages.append(contentsOf: interleaved)

                if let record = AssistantMessagePayload(from: event.payload)?.tokenRecord {
                    state.totalTokenUsage = TokenUsage(
                        inputTokens: state.totalTokenUsage.inputTokens + record.source.rawInputTokens,
                        outputTokens: state.totalTokenUsage.outputTokens + record.source.rawOutputTokens,
                        cacheReadTokens: (state.totalTokenUsage.cacheReadTokens ?? 0) + record.source.rawCacheReadTokens,
                        cacheCreationTokens: (state.totalTokenUsage.cacheCreationTokens ?? 0) + record.source.rawCacheCreationTokens
                    )
                    state.lastTurnInputTokens = record.computed.contextWindowTokens
                }

            case .messageUser, .turnFailed:
                if var message = transformPersistedEvent(event) {
                    if eventType == .messageUser {
                        message.eventId = event.id
                    }
                    state.messages.append(message)
                }

            case .compactBoundary:
                if let message = transformPersistedEvent(event) {
                    state.messages.append(message)
                }
                if let parsed = CompactBoundaryPayload(from: event.payload) {
                    // Update context tokens so pill reflects post-compaction state on resume.
                    // If a later message.assistant arrives with a tokenRecord, it overwrites with API ground truth.
                    state.lastTurnInputTokens = parsed.estimatedContextTokens ?? parsed.compactedTokens
                }

            default:
                break
            }
        }

        state.messages =
            AgentDeliveryContinuationPresentation.deduplicatingTranscript(
                state.messages
            )
        return state
    }
}
