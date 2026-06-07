import Foundation

// ARCHITECTURE: ~591 lines — dual-path transformer (persisted events + live streaming
// events) producing ChatMessages. Both paths share block-building logic for text,
// capability invocations, and thinking content. Splitting would duplicate the shared
// content-block assembly.

// =============================================================================
// MARK: - Unified Event Transformer
// =============================================================================

/// The single source of truth for transforming server events into ChatMessages.
///
/// This transformer handles BOTH:
/// 1. Persisted events (from `events::get_history` engine protocol / SQLite)
/// 2. Streaming events (from WebSocket during live agent execution)
///
/// ## Architecture Principle
/// **Content block order is the source of truth for interleaving.**
///
/// The server sends `message.assistant` events with content blocks in exact
/// streaming order via `currentTurnContentSequence`. This preserves the interleaving
/// of text and capability invocations as they appeared during streaming:
///
/// ```
/// [text: "I'll run sleep 3...", capability_invocation: {id: "t1"}, text: "Done!", ...]
/// ```
///
/// Capability details come from separate `capability.invocation.started` events (identity, arguments, turn).
/// Capability results come from `capability.invocation.completed` events. Both are combined when rendering
/// capability_invocation content blocks from the message.assistant.
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
    /// **Important**: Capability invocations (`capability.invocation.started`) are combined with their results
    /// (`capability.invocation.completed`) into a single message. This matches the streaming UI
    /// behavior where capability invocations show their results inline.
    ///
    /// - Parameters:
    ///   - events: Events conforming to EventTransformable
    ///   - presorted: Whether `events` already arrive in chronological chain order.
    /// - Returns: Array of ChatMessages in chronological order
    static func transformPersistedEvents<E: EventTransformable>(_ events: [E], presorted: Bool = false) -> [ChatMessage] {
        let sorted = presorted ? events : EventSorter.sortBySequence(events)

        // Build maps for capability invocation rendering.
        let maps = buildCapabilityInvocationMaps(from: sorted)
        let startedInvocations = maps.startedInvocations
        let completedInvocations = maps.completedInvocations

        TronLogger.shared.debug("[RECONSTRUCT] Built maps: \(startedInvocations.count) capability.invocation.started, \(completedInvocations.count) capability.invocation.completed from \(sorted.count) events", category: .session)

        // Transform events, processing message.assistant content blocks in order
        var messages: [ChatMessage] = []
        for event in sorted {
            // Skip capability.invocation.started, capability.invocation.completed, and stream.thinking_complete —
            // all are processed via message.assistant content blocks
            if event.type == PersistedEventType.capabilityInvocationStarted.rawValue ||
               event.type == PersistedEventType.capabilityInvocationCompleted.rawValue ||
               event.type == PersistedEventType.streamThinkingComplete.rawValue {
                continue
            }

            // message.assistant: process content blocks in order (preserves interleaving)
            if event.type == PersistedEventType.messageAssistant.rawValue {
                var interleaved = InterleavedContentProcessor.transform(
                    payload: event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    startedInvocations: startedInvocations,
                    completedInvocations: completedInvocations
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

        return messages
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
        case .capabilityInvocationStarted:
            return CapabilityInvocationHandlers.transformInvocationStarted(payload, timestamp: ts)
        case .capabilityInvocationCompleted:
            return CapabilityInvocationHandlers.transformInvocationCompleted(payload, timestamp: ts)
        case .notificationInterrupted:
            return SystemEventHandlers.transformInterrupted(payload, timestamp: ts)
        case .configModelSwitch:
            return ConfigHandlers.transformModelSwitch(payload, timestamp: ts)
        case .configReasoningLevel:
            return ConfigHandlers.transformReasoningLevelChange(payload, timestamp: ts)
        case .errorAgent:
            return ErrorHandlers.transformAgentError(payload, timestamp: ts)
        case .errorCapability:
            return ErrorHandlers.transformCapabilityError(payload, timestamp: ts)
        case .errorProvider:
            return ErrorHandlers.transformProviderError(payload, timestamp: ts)
        case .turnFailed:
            return ErrorHandlers.transformTurnFailed(payload, timestamp: ts)
        case .contextCleared:
            return SystemEventHandlers.transformContextCleared(payload, timestamp: ts)
        case .compactBoundary:
            return SystemEventHandlers.transformCompactBoundary(payload, timestamp: ts)
        default:
            return nil
        }
    }

    // =========================================================================
    // MARK: - Capability Invocation Map Collection (shared between transform and reconstruct)
    // =========================================================================

    /// Result of the first-pass collection over events.
    /// Both `transformPersistedEvents` and `reconstructSessionState` need these maps
    /// to resolve provider `capability_invocation` content blocks.
    struct CapabilityInvocationMapResult {
        var startedInvocations: [String: CapabilityInvocationStartedPayload] = [:]
        var completedInvocations: [String: CapabilityInvocationCompletedPayload] = [:]
    }

    /// Single-pass collection of started/completed capability invocations from a sorted event array.
    static func buildCapabilityInvocationMaps<E: EventTransformable>(from events: [E]) -> CapabilityInvocationMapResult {
        var result = CapabilityInvocationMapResult()
        for event in events {
            if event.type == PersistedEventType.capabilityInvocationStarted.rawValue,
               let payload = CapabilityInvocationStartedPayload(from: event.payload) {
                result.startedInvocations[payload.invocationId] = payload
            }
            if event.type == PersistedEventType.capabilityInvocationCompleted.rawValue,
               let payload = CapabilityInvocationCompletedPayload(from: event.payload) {
                result.completedInvocations[payload.invocationId] = payload
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

    /// Reconstruct full session state from persisted events.
    ///
    /// This generic implementation works with any `EventTransformable` type,
    /// processing all events in order to extract:
    /// - Chat messages for display
    /// - Accumulated token usage
    /// - Current model (after any switches)
    /// - Working directory
    /// - Extended state (file activity, compaction, metadata, etc.)
    ///
    /// **Two-Pass Reconstruction**:
    /// - Pass 1: Collect deleted event IDs, capability invocation maps, and config state
    /// - Pass 2: Build messages while filtering deleted events
    ///
    /// **UserInteraction Status Detection**:
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

        // PASS 1: Collect capability invocation maps (shared), plus deleted event IDs and config state (reconstruct-only).
        let maps = buildCapabilityInvocationMaps(from: sorted)
        let startedInvocations = maps.startedInvocations
        let completedInvocations = maps.completedInvocations

        var deletedEventIds = Set<String>()
        for event in sorted {
            if event.type == PersistedEventType.messageDeleted.rawValue,
               let payload = MessageDeletedPayload(from: event.payload) {
                deletedEventIds.insert(payload.targetEventId)
            }
            if event.type == PersistedEventType.configReasoningLevel.rawValue {
                let payload = ReasoningLevelPayload(from: event.payload)
                state.reasoningLevel = payload.newLevel
            }
        }

        // PASS 2: Build messages, skipping deleted and consumed events
        for event in sorted {
            if deletedEventIds.contains(event.id) {
                continue
            }
            guard let eventType = PersistedEventType(rawValue: event.type) else { continue }

            switch eventType {
            case .sessionStart:
                if let payload = SessionStartPayload(from: event.payload) {
                    state.currentModel = payload.model
                    state.workingDirectory = payload.workingDirectory
                    state.sessionInfo.startTime = parseTimestamp(event.timestamp)
                    state.sessionInfo.initialModel = payload.model
                }

            case .capabilityInvocationCompleted, .capabilityInvocationStarted, .streamThinkingComplete:
                // Skip - processed via message.assistant content blocks
                break

            case .messageAssistant:
                var interleaved = InterleavedContentProcessor.transform(
                    payload: event.payload,
                    timestamp: parseTimestamp(event.timestamp),
                    startedInvocations: startedInvocations,
                    completedInvocations: completedInvocations
                )
                if !interleaved.isEmpty {
                    interleaved[0].eventId = event.id
                }
                state.messages.append(contentsOf: interleaved)

                let parsedPayload = AssistantMessagePayload(from: event.payload)
                if let parsed = parsedPayload, let record = parsed.tokenRecord {
                    state.totalTokenUsage = TokenUsage(
                        inputTokens: state.totalTokenUsage.inputTokens + record.source.rawInputTokens,
                        outputTokens: state.totalTokenUsage.outputTokens + record.source.rawOutputTokens,
                        cacheReadTokens: (state.totalTokenUsage.cacheReadTokens ?? 0) + record.source.rawCacheReadTokens,
                        cacheCreationTokens: (state.totalTokenUsage.cacheCreationTokens ?? 0) + record.source.rawCacheCreationTokens
                    )
                    state.lastTurnInputTokens = record.computed.contextWindowTokens
                }
                if let parsed = parsedPayload, parsed.turn > state.currentTurn {
                    state.currentTurn = parsed.turn
                }

            case .messageUser, .messageSystem,
                 .notificationInterrupted,
                 .configModelSwitch, .configReasoningLevel,
                 .contextCleared,
                 .errorAgent, .errorCapability, .errorProvider, .turnFailed:
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

            case .streamTurnEnd:
                if let payload = StreamTurnEndPayload(from: event.payload),
                   payload.turn > state.currentTurn {
                    state.currentTurn = payload.turn
                }

            case .sessionBranch:
                if let parsed = SessionBranchPayload(from: event.payload) {
                    state.sessionInfo.branchName = parsed.name
                }

            case .fileRead, .fileWrite, .fileEdit:
                handleFileActivityEvent(eventType, payload: event.payload,
                                        timestamp: event.timestamp, state: &state)

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
                    // Update context tokens so pill reflects post-compaction state on resume.
                    // If a later message.assistant arrives with a tokenRecord, it overwrites with API ground truth.
                    state.lastTurnInputTokens = parsed.estimatedContextTokens ?? parsed.compactedTokens
                }

            case .metadataUpdate, .metadataTag, .llmHookResult:
                handleMetadataEvent(eventType, payload: event.payload,
                                    timestamp: event.timestamp, state: &state)

            default:
                break
            }
        }

        return state
    }

    // =========================================================================
    // MARK: - Reconstruction Event Handlers
    // =========================================================================

    private static func handleFileActivityEvent(
        _ eventType: PersistedEventType,
        payload: [String: AnyCodable],
        timestamp: String,
        state: inout ReconstructedState
    ) {
        let ts = parseTimestamp(timestamp)

        switch eventType {
        case .fileRead:
            if let parsed = FileReadPayload(from: payload) {
                state.fileActivity.reads.append(ReconstructedState.FileActivityState.FileRead(
                    path: parsed.path, timestamp: ts,
                    linesStart: parsed.linesStart, linesEnd: parsed.linesEnd
                ))
            }
        case .fileWrite:
            if let parsed = FileWritePayload(from: payload) {
                state.fileActivity.writes.append(ReconstructedState.FileActivityState.FileWrite(
                    path: parsed.path, timestamp: ts,
                    size: parsed.size, contentHash: parsed.contentHash
                ))
            }
        case .fileEdit:
            if let parsed = FileEditPayload(from: payload) {
                state.fileActivity.edits.append(ReconstructedState.FileActivityState.FileEdit(
                    path: parsed.path, timestamp: ts,
                    oldString: parsed.oldString, newString: parsed.newString, diff: parsed.diff
                ))
            }
        default:
            break
        }
    }

    private static func handleMetadataEvent(
        _ eventType: PersistedEventType,
        payload: [String: AnyCodable],
        timestamp: String,
        state: inout ReconstructedState
    ) {
        switch eventType {
        case .metadataUpdate:
            if let parsed = MetadataUpdatePayload(from: payload) {
                state.metadata.customData[parsed.key] = parsed.newValue
                state.metadata.lastUpdated = parseTimestamp(timestamp)
            }
        case .metadataTag:
            if let parsed = MetadataTagPayload(from: payload) {
                if parsed.action == "add" && !state.tags.contains(parsed.tag) {
                    state.tags.append(parsed.tag)
                } else if parsed.action == "remove" {
                    state.tags.removeAll { $0 == parsed.tag }
                }
            }
        case .llmHookResult:
            if let hookId = payload["hookId"]?.value as? String,
               hookId.contains("suggest-prompts"),
               let success = payload["success"]?.value as? Bool,
               success,
               let output = payload["output"]?.value as? String {
                let suggestions = output
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.count < 80 }
                state.suggestions = Array(suggestions.prefix(5))
            }
        default:
            break
        }
    }
}
