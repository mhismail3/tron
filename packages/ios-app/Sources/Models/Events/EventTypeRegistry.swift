import Foundation

// =============================================================================
// MARK: - Persisted Event Types (from server core/src/events/types.ts)
// =============================================================================

/// All persisted event types that are stored in the event database.
/// This EXACTLY mirrors the server's EventType union in types.ts.
///
/// These events are retrieved via `events.getHistory` RPC and represent
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

    // Tool execution
    case toolCall = "tool.call"
    case toolResult = "tool.result"

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

    // Notifications (in-chat pill notifications)
    case notificationInterrupted = "notification.interrupted"
    case notificationSubagentResult = "notification.subagent_result"

    // Skills
    case skillAdded = "skill.added"
    case skillRemoved = "skill.removed"

    // Rules
    case rulesLoaded = "rules.loaded"

    // Compaction/summarization
    case compactBoundary = "compact.boundary"
    case compactSummary = "compact.summary"

    // Context clearing
    case contextCleared = "context.cleared"

    // Metadata
    case metadataUpdate = "metadata.update"
    case metadataTag = "metadata.tag"

    // File operations (for change tracking)
    case fileRead = "file.read"
    case fileWrite = "file.write"
    case fileEdit = "file.edit"

    // Worktree/git operations
    case worktreeAcquired = "worktree.acquired"
    case worktreeCommit = "worktree.commit"
    case worktreeReleased = "worktree.released"
    case worktreeMerged = "worktree.merged"

    // Error events
    case errorAgent = "error.agent"
    case errorTool = "error.tool"
    case errorProvider = "error.provider"

    // Turn events
    case turnFailed = "turn.failed"

    // MARK: - Display Classification

    /// Whether this event type should render as a ChatMessage in the chat UI
    var rendersAsChatMessage: Bool {
        switch self {
        case .messageUser, .messageAssistant, .messageSystem,
             .toolCall, .toolResult,
             .notificationInterrupted, .notificationSubagentResult,
             .configModelSwitch, .configReasoningLevel,
             .contextCleared, .compactBoundary, .skillRemoved, .rulesLoaded,
             .errorAgent, .errorTool, .errorProvider,
             .streamThinkingComplete, .turnFailed:
            return true
        default:
            return false
        }
    }

    /// Whether this event affects session state reconstruction
    var affectsSessionState: Bool {
        switch self {
        case .sessionStart, .sessionEnd, .sessionFork,
             .messageUser, .messageAssistant, .messageSystem,
             .messageDeleted,
             .toolCall, .toolResult,
             .configModelSwitch, .configPromptUpdate, .configReasoningLevel,
             .compactBoundary, .compactSummary,
             .worktreeAcquired, .worktreeCommit, .worktreeReleased, .worktreeMerged,
             .errorAgent:
            return true
        default:
            return false
        }
    }

    /// Whether this is a streaming-related event (real-time reconstruction)
    var isStreamingEvent: Bool {
        switch self {
        case .streamTextDelta, .streamThinkingDelta, .streamThinkingComplete, .streamTurnStart, .streamTurnEnd:
            return true
        default:
            return false
        }
    }

    /// Whether this event is metadata-only (not displayed in main chat)
    var isMetadataOnly: Bool {
        switch self {
        case .sessionStart, .sessionEnd, .sessionFork, .sessionBranch,
             .compactBoundary, .compactSummary,
             .metadataUpdate, .metadataTag,
             .worktreeAcquired, .worktreeReleased, .worktreeCommit, .worktreeMerged,
             .streamTextDelta, .streamThinkingDelta, .streamTurnStart, .streamTurnEnd,
             .configPromptUpdate,
             .messageDeleted,
             .fileRead, .fileWrite, .fileEdit:
            return true
        default:
            return false
        }
    }

    /// Human-readable description for debugging
    var displayDescription: String {
        switch self {
        case .sessionStart: return "Session started"
        case .sessionEnd: return "Session ended"
        case .sessionFork: return "Session forked"
        case .sessionBranch: return "Branch created"
        case .messageUser: return "User message"
        case .messageAssistant: return "Assistant message"
        case .messageSystem: return "System message"
        case .toolCall: return "Tool call"
        case .toolResult: return "Tool result"
        case .streamTextDelta: return "Text delta"
        case .streamThinkingDelta: return "Thinking delta"
        case .streamThinkingComplete: return "Thinking complete"
        case .streamTurnStart: return "Turn started"
        case .streamTurnEnd: return "Turn ended"
        case .configModelSwitch: return "Model switched"
        case .configPromptUpdate: return "Prompt updated"
        case .configReasoningLevel: return "Reasoning level changed"
        case .messageDeleted: return "Message deleted"
        case .notificationInterrupted: return "Session interrupted"
        case .notificationSubagentResult: return "Subagent result available"
        case .skillAdded: return "Skill added"
        case .skillRemoved: return "Skill removed"
        case .rulesLoaded: return "Rules loaded"
        case .compactBoundary: return "Compact boundary"
        case .compactSummary: return "Compact summary"
        case .contextCleared: return "Context cleared"
        case .metadataUpdate: return "Metadata updated"
        case .metadataTag: return "Tag updated"
        case .fileRead: return "File read"
        case .fileWrite: return "File write"
        case .fileEdit: return "File edit"
        case .worktreeAcquired: return "Worktree acquired"
        case .worktreeCommit: return "Git commit"
        case .worktreeReleased: return "Worktree released"
        case .worktreeMerged: return "Worktree merged"
        case .errorAgent: return "Agent error"
        case .errorTool: return "Tool error"
        case .errorProvider: return "Provider error"
        case .turnFailed: return "Turn failed"
        }
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
    case toolUse = "tool_use"
    case toolResult = "tool_result"
    case thinking = "thinking"
}

// =============================================================================
// MARK: - Stop Reasons (from server AssistantMessageEvent)
// =============================================================================

/// Stop reasons for assistant messages.
/// This EXACTLY mirrors the server's stopReason union.
enum StopReason: String {
    case endTurn = "end_turn"
    case toolUse = "tool_use"
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

// =============================================================================
// MARK: - Worktree Merge Strategies (from server WorktreeMergedEvent)
// =============================================================================

/// Git merge strategies.
/// This EXACTLY mirrors the server's strategy union.
enum MergeStrategy: String {
    case merge = "merge"
    case rebase = "rebase"
    case squash = "squash"
}
