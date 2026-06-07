import Foundation

// =============================================================================
// MARK: - Persisted Event Types (from server core/src/events/types.ts)
// =============================================================================

/// All persisted event types that are stored in the event database.
/// This EXACTLY mirrors the server's EventType union in types.ts.
///
/// These events are retrieved via `events::get_history` engine protocol and represent
/// the immutable event log that forms the session tree.
enum PersistedEventType: String, CaseIterable {
    // Session lifecycle
    case sessionStart = "session.start"
    case sessionEnd = "session.end"
    case sessionFork = "session.fork"
    case sessionBranch = "session.branch"

    // Conversation
    case messageUser = "message.user"
    case messageAssistant = "message.assistant"
    case messageSystem = "message.system"

    // Capability execution
    case capabilityInvocationStarted = "capability.invocation.started"
    case capabilityInvocationCompleted = "capability.invocation.completed"
    case capabilityRunStatus = "capability.run.status"

    // Streaming (for real-time reconstruction)
    case streamTextDelta = "stream.text_delta"
    case streamThinkingDelta = "stream.thinking_delta"
    case streamThinkingComplete = "stream.thinking_complete"
    case streamTurnStart = "stream.turn_start"
    case streamTurnEnd = "stream.turn_end"

    // Model/config changes
    case configModelSwitch = "config.model_switch"
    case configPromptUpdate = "config.prompt_update"
    case configReasoningLevel = "config.reasoning_level"

    // Message operations
    case messageDeleted = "message.deleted"

    // Compaction/summarization
    case compactBoundary = "compact.boundary"

    // Context clearing
    case contextCleared = "context.cleared"

    // Metadata
    case metadataUpdate = "metadata.update"
    case metadataTag = "metadata.tag"

    // File operations (for change tracking)
    case fileRead = "file.read"
    case fileWrite = "file.write"
    case fileEdit = "file.edit"

    // Error events
    case errorAgent = "error.agent"
    case errorCapability = "error.capability"
    case errorProvider = "error.provider"

    // Turn events
    case turnFailed = "turn.failed"

    // Hooks
    case llmHookResult = "hook.llm_result"

    // MARK: - Classification (single source of truth)

    /// All classification flags for this event type, consolidated into one switch.
    /// The public `rendersAsChatMessage`/`affectsSessionState`/`isStreamingEvent`/
    /// `isMetadataOnly`/`displayDescription` properties below are thin forwarders
    /// so callers read the right flag by name; this private computed property is
    /// the only place the classification itself is defined.
    private var classification: EventClassification {
        //                                                    renders  affects  stream  meta
        switch self {
        // Session lifecycle
        case .sessionStart:            return .init(false,   true,    false,   true,   "Session started")
        case .sessionEnd:              return .init(false,   false,   false,   true,   "Session ended")
        case .sessionFork:             return .init(false,   true,    false,   true,   "Session forked")
        case .sessionBranch:           return .init(false,   false,   false,   true,   "Branch created")
        // Conversation
        case .messageUser:             return .init(true,    true,    false,   false,  "User message")
        case .messageAssistant:        return .init(true,    true,    false,   false,  "Assistant message")
        case .messageSystem:           return .init(true,    true,    false,   false,  "System message")
        // Capability execution
        case .capabilityInvocationStarted: return .init(true, true, false, false, "Capability invocation")
        case .capabilityInvocationCompleted: return .init(true, true, false, false, "Capability result")
        case .capabilityRunStatus: return .init(false, true, false, true, "Capability run status")
        // Streaming
        case .streamTextDelta:         return .init(false,   false,   true,    true,   "Text delta")
        case .streamThinkingDelta:     return .init(false,   false,   true,    true,   "Thinking delta")
        case .streamThinkingComplete:  return .init(false,   false,   true,    false,  "Thinking complete")
        case .streamTurnStart:         return .init(false,   false,   true,    true,   "Turn started")
        case .streamTurnEnd:           return .init(false,   false,   true,    true,   "Turn ended")
        // Model/config
        case .configModelSwitch:       return .init(true,    true,    false,   false,  "Model switched")
        case .configPromptUpdate:      return .init(false,   true,    false,   true,   "Prompt updated")
        case .configReasoningLevel:    return .init(true,    true,    false,   false,  "Reasoning level changed")
        // Message operations
        case .messageDeleted:          return .init(false,   true,    false,   true,   "Message deleted")
        // Compaction
        case .compactBoundary:         return .init(true,    true,    false,   true,   "Compact boundary")
        // Context
        case .contextCleared:          return .init(true,    false,   false,   false,  "Context cleared")
        // Metadata
        case .metadataUpdate:          return .init(false,   false,   false,   true,   "Metadata updated")
        case .metadataTag:             return .init(false,   false,   false,   true,   "Tag updated")
        // File operations
        case .fileRead:                return .init(false,   false,   false,   true,   "File read")
        case .fileWrite:               return .init(false,   false,   false,   true,   "File write")
        case .fileEdit:                return .init(false,   false,   false,   true,   "File edit")
        // Errors
        case .errorAgent:              return .init(true,    true,    false,   false,  "Agent error")
        case .errorCapability:               return .init(true,    false,   false,   false,  "Capability error")
        case .errorProvider:           return .init(true,    false,   false,   false,  "Provider error")
        // Turn events
        case .turnFailed:              return .init(true,    false,   false,   false,  "Turn failed")
        // Hooks
        case .llmHookResult:           return .init(false,   true,    false,   true,   "LLM hook result")
        }
    }

    var rendersAsChatMessage: Bool { classification.rendersAsChatMessage }
    var affectsSessionState: Bool { classification.affectsSessionState }
    var isStreamingEvent: Bool { classification.isStreamingEvent }
    var isMetadataOnly: Bool { classification.isMetadataOnly }
    var displayDescription: String { classification.displayDescription }
}

// =============================================================================
// MARK: - Event Classification
// =============================================================================

/// Consolidated classification flags for an event type.
/// Single source of truth — each event case maps to exactly one of these.
private struct EventClassification {
    let rendersAsChatMessage: Bool
    let affectsSessionState: Bool
    let isStreamingEvent: Bool
    let isMetadataOnly: Bool
    let displayDescription: String

    init(_ renders: Bool, _ affects: Bool, _ streaming: Bool, _ metadata: Bool, _ description: String) {
        self.rendersAsChatMessage = renders
        self.affectsSessionState = affects
        self.isStreamingEvent = streaming
        self.isMetadataOnly = metadata
        self.displayDescription = description
    }
}

// =============================================================================
// MARK: - Content Block Types (from server types.ts ContentBlock)
// =============================================================================

/// Content block types used in message payloads.
/// This EXACTLY mirrors the server's ContentBlock union.
enum ContentBlockType: String {
    case text = "text"
    case image = "image"
    case document = "document"
    case capabilityInvocation = "capability_invocation"
    case capabilityResult = "capability_result"
    case thinking = "thinking"
}

// =============================================================================
// MARK: - Capability Call Status (from server CapabilityInvocationEvent)
// =============================================================================

/// Status of a capability invocation execution.
enum CapabilityInvocationStatusDTO: String {
    case generating = "generating"
    case running = "running"
    case paused = "paused"
    case completed = "completed"
    case error = "error"
}

// =============================================================================
// MARK: - Stop Reasons (from server AssistantMessageEvent)
// =============================================================================

/// Stop reasons for assistant messages.
/// This EXACTLY mirrors the server's stopReason union.
enum StopReason: String {
    case endTurn = "end_turn"
    case capabilityInvocation = "capability_invocation"
    case maxTokens = "max_tokens"
    case stopSequence = "stop_sequence"
}

// =============================================================================
// MARK: - Session End Reasons (from server SessionEndEvent)
// =============================================================================

/// Reasons for session termination.
/// This EXACTLY mirrors the server's reason union.
enum SessionEndReason: String {
    case completed = "completed"
    case aborted = "aborted"
    case error = "error"
    case timeout = "timeout"
}

// =============================================================================
// MARK: - System Message Sources (from server SystemMessageEvent)
// =============================================================================

/// Sources for system messages.
/// This EXACTLY mirrors the server's source union.
enum SystemMessageSource: String {
    case compaction = "compaction"
    case context = "context"
    case hook = "hook"
    case error = "error"
    case inject = "inject"
}
