import Foundation

// =============================================================================
// MARK: - Persisted Event Payloads (from server core/src/events/types.ts)
// =============================================================================

// These payload structures EXACTLY mirror the server's event payload types.
// Each struct corresponds to a specific PersistedEventType.

// MARK: - Session Lifecycle Payloads

/// Payload for session.start event
/// Server: SessionStartEvent.payload
struct SessionStartPayload {
    let workingDirectory: String
    let model: String
    let provider: String
    let systemPrompt: String?
    let title: String?
    let tags: [String]?
    let forkedFrom: ForkedFromInfo?

    struct ForkedFromInfo {
        let sessionId: String
        let eventId: String
    }

    init(from payload: [String: AnyCodable]) {
        self.workingDirectory = payload.string("workingDirectory") ?? ""
        self.model = payload.string("model") ?? ""
        self.provider = payload.string("provider") ?? ""
        self.systemPrompt = payload.string("systemPrompt")
        self.title = payload.string("title")
        self.tags = payload.stringArray("tags")

        if let forked = payload.dict("forkedFrom") {
            self.forkedFrom = ForkedFromInfo(
                sessionId: forked["sessionId"] as? String ?? "",
                eventId: forked["eventId"] as? String ?? ""
            )
        } else {
            self.forkedFrom = nil
        }
    }
}

/// Payload for session.end event
/// Server: SessionEndEvent.payload
struct SessionEndPayload {
    let reason: SessionEndReason?
    let summary: String?
    let totalTokenUsage: TokenUsage?
    let duration: Int?  // milliseconds

    init(from payload: [String: AnyCodable]) {
        if let reasonStr = payload.string("reason") {
            self.reason = SessionEndReason(rawValue: reasonStr)
        } else {
            self.reason = nil
        }
        self.summary = payload.string("summary")
        self.duration = payload.int("duration")

        if let usage = payload.dict("totalTokenUsage") {
            self.totalTokenUsage = TokenUsage(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.totalTokenUsage = nil
        }
    }
}

/// Payload for session.fork event
/// Server: SessionForkEvent.payload
struct SessionForkPayload {
    let sourceSessionId: String
    let sourceEventId: String
    let name: String?
    let reason: String?

    init?(from payload: [String: AnyCodable]) {
        guard let sourceSessionId = payload.string("sourceSessionId"),
              let sourceEventId = payload.string("sourceEventId") else {
            return nil
        }
        self.sourceSessionId = sourceSessionId
        self.sourceEventId = sourceEventId
        self.name = payload.string("name")
        self.reason = payload.string("reason")
    }
}

/// Payload for session.branch event
/// Server: SessionBranchEvent.payload
struct SessionBranchPayload {
    let branchId: String
    let name: String
    let description: String?

    init?(from payload: [String: AnyCodable]) {
        guard let branchId = payload.string("branchId"),
              let name = payload.string("name") else {
            return nil
        }
        self.branchId = branchId
        self.name = name
        self.description = payload.string("description")
    }
}

// MARK: - Message Payloads

/// Payload for message.user event
/// Server: UserMessageEvent.payload
struct UserMessagePayload {
    let content: String
    let turn: Int
    let imageCount: Int?

    init?(from payload: [String: AnyCodable]) {
        // Content can be a string or array of content blocks
        if let content = payload.string("content") {
            self.content = content
        } else if let contentBlocks = payload["content"]?.value as? [[String: Any]] {
            // Extract text from content blocks
            let texts = contentBlocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            self.content = texts.joined(separator: "\n")
        } else {
            return nil
        }

        self.turn = payload.int("turn") ?? 1
        self.imageCount = payload.int("imageCount")
    }
}

/// Payload for message.assistant event
/// Server: AssistantMessageEvent.payload
///
/// IMPORTANT: This payload contains ContentBlocks which may include tool_use blocks.
/// However, tool_use blocks should be IGNORED here - they are rendered via tool.call events.
struct AssistantMessagePayload {
    let contentBlocks: [[String: Any]]?
    let turn: Int
    let tokenUsage: TokenUsage?
    let stopReason: StopReason?
    let latencyMs: Int?
    let model: String?
    let hasThinking: Bool?
    let interrupted: Bool?

    /// Extracts ONLY the text content, ignoring tool_use blocks
    /// Tool calls are rendered via separate tool.call events
    var textContent: String? {
        guard let blocks = contentBlocks else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Extracts thinking content if present
    var thinkingContent: String? {
        guard let blocks = contentBlocks else { return nil }
        let thoughts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "thinking" else { return nil }
            return block["thinking"] as? String
        }
        return thoughts.isEmpty ? nil : thoughts.joined(separator: "\n")
    }

    init(from payload: [String: AnyCodable]) {
        // Content can be array of blocks or direct string (legacy)
        if let blocks = payload["content"]?.value as? [[String: Any]] {
            self.contentBlocks = blocks
        } else if let text = payload.string("content") {
            // Legacy: convert string to text block
            self.contentBlocks = [["type": "text", "text": text]]
        } else if let text = payload.string("text") {
            // Alternative field name
            self.contentBlocks = [["type": "text", "text": text]]
        } else {
            self.contentBlocks = nil
        }

        self.turn = payload.int("turn") ?? 1

        if let usage = payload.dict("tokenUsage") {
            self.tokenUsage = TokenUsage(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.tokenUsage = nil
        }

        if let stopStr = payload.string("stopReason") {
            self.stopReason = StopReason(rawValue: stopStr)
        } else {
            self.stopReason = nil
        }

        self.latencyMs = payload.int("latency") ?? payload.int("latencyMs")
        self.model = payload.string("model")
        self.hasThinking = payload.bool("hasThinking")
        self.interrupted = payload.bool("interrupted")
    }
}

/// Payload for message.system event
/// Server: SystemMessageEvent.payload
struct SystemMessagePayload {
    let content: String
    let source: SystemMessageSource?

    init?(from payload: [String: AnyCodable]) {
        guard let content = payload.string("content") else {
            return nil
        }
        self.content = content

        if let sourceStr = payload.string("source") {
            self.source = SystemMessageSource(rawValue: sourceStr)
        } else {
            self.source = nil
        }
    }
}

// MARK: - Tool Payloads

/// Payload for tool.call event
/// Server: ToolCallEvent.payload
struct ToolCallPayload {
    let toolCallId: String
    let name: String
    let arguments: String  // JSON string for display
    let turn: Int

    init?(from payload: [String: AnyCodable]) {
        // toolCallId can be "toolCallId" or "id"
        guard let id = payload.string("toolCallId") ?? payload.string("id"),
              let name = payload.string("name") else {
            return nil
        }

        self.toolCallId = id
        self.name = name
        self.turn = payload.int("turn") ?? 1

        // Arguments can be dict or string
        if let argsDict = payload.dict("arguments"),
           let jsonData = try? JSONSerialization.data(withJSONObject: argsDict, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.arguments = jsonString
        } else if let argsStr = payload.string("arguments") {
            self.arguments = argsStr
        } else {
            self.arguments = "{}"
        }
    }
}

/// Payload for tool.result event
/// Server: ToolResultEvent.payload
struct ToolResultPayload {
    let toolCallId: String
    let content: String
    let isError: Bool
    let durationMs: Int
    let affectedFiles: [String]?
    let truncated: Bool?

    // Additional fields for display (may come from enrichment)
    let name: String?
    let arguments: String?

    init?(from payload: [String: AnyCodable]) {
        guard let toolCallId = payload.string("toolCallId") else {
            return nil
        }

        self.toolCallId = toolCallId
        self.content = payload.string("content") ?? ""
        self.isError = payload.bool("isError") ?? false
        self.durationMs = payload.int("duration") ?? payload.int("durationMs") ?? 0
        self.affectedFiles = payload.stringArray("affectedFiles")
        self.truncated = payload.bool("truncated")

        // Optional enrichment fields
        self.name = payload.string("name")
        if let argsDict = payload.dict("arguments"),
           let jsonData = try? JSONSerialization.data(withJSONObject: argsDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.arguments = jsonString
        } else if let argsStr = payload.string("arguments") {
            self.arguments = argsStr
        } else {
            self.arguments = nil
        }
    }
}

// MARK: - Config Payloads

/// Payload for config.model_switch event
/// Server: ConfigModelSwitchEvent.payload
struct ModelSwitchPayload {
    let previousModel: String
    let newModel: String
    let reason: String?

    init?(from payload: [String: AnyCodable]) {
        guard let previousModel = payload.string("previousModel") else {
            return nil
        }

        self.previousModel = previousModel
        self.newModel = payload.string("newModel")
            ?? payload.string("model") ?? ""
        self.reason = payload.string("reason")
    }
}

/// Payload for config.prompt_update event
/// Server: ConfigPromptUpdateEvent.payload
struct ConfigPromptUpdatePayload {
    let previousHash: String?
    let newHash: String
    let contentBlobId: String?

    init?(from payload: [String: AnyCodable]) {
        guard let newHash = payload.string("newHash") else {
            return nil
        }
        self.previousHash = payload.string("previousHash")
        self.newHash = newHash
        self.contentBlobId = payload.string("contentBlobId")
    }
}

// MARK: - Notification Payloads

/// Payload for notification.interrupted event
struct InterruptedPayload {
    let timestamp: String?
    let turn: Int?

    init(from payload: [String: AnyCodable]) {
        self.timestamp = payload.string("timestamp")
        self.turn = payload.int("turn")
    }
}

// MARK: - Error Payloads

/// Payload for error.agent event
/// Server: ErrorAgentEvent.payload
struct AgentErrorPayload {
    let error: String
    let code: String?
    let recoverable: Bool

    init?(from payload: [String: AnyCodable]) {
        guard let error = payload.string("error")
                ?? payload.string("message") else {
            return nil
        }

        self.error = error
        self.code = payload.string("code")
        self.recoverable = payload.bool("recoverable") ?? false
    }
}

/// Payload for error.tool event
/// Server: ErrorToolEvent.payload
struct ToolErrorPayload {
    let toolName: String
    let toolCallId: String
    let error: String
    let code: String?

    init?(from payload: [String: AnyCodable]) {
        guard let toolName = payload.string("toolName"),
              let toolCallId = payload.string("toolCallId"),
              let error = payload.string("error") else {
            return nil
        }

        self.toolName = toolName
        self.toolCallId = toolCallId
        self.error = error
        self.code = payload.string("code")
    }
}

/// Payload for error.provider event
/// Server: ErrorProviderEvent.payload
struct ProviderErrorPayload {
    let provider: String
    let error: String
    let code: String?
    let retryable: Bool
    let retryAfter: Int?

    init?(from payload: [String: AnyCodable]) {
        guard let provider = payload.string("provider"),
              let error = payload.string("error") else {
            return nil
        }

        self.provider = provider
        self.error = error
        self.code = payload.string("code")
        self.retryable = payload.bool("retryable") ?? false
        self.retryAfter = payload.int("retryAfter")
    }
}

// MARK: - Ledger Payloads

/// Payload for ledger.update event
/// Server: LedgerUpdateEvent.payload
struct LedgerUpdatePayload {
    let field: LedgerField?
    let previousValue: Any?
    let newValue: Any?

    init(from payload: [String: AnyCodable]) {
        if let fieldStr = payload.string("field") {
            self.field = LedgerField(rawValue: fieldStr)
        } else {
            self.field = nil
        }
        self.previousValue = payload["previousValue"]?.value
        self.newValue = payload["newValue"]?.value
    }
}

/// Payload for ledger.goal event
/// Server: LedgerGoalEvent.payload
struct LedgerGoalPayload {
    let goal: String

    init?(from payload: [String: AnyCodable]) {
        guard let goal = payload.string("goal") else {
            return nil
        }
        self.goal = goal
    }
}

/// Payload for ledger.task event
/// Server: LedgerTaskEvent.payload
struct LedgerTaskPayload {
    let action: String  // "add" | "complete" | "remove"
    let task: String
    let list: String    // "next" | "done"

    init?(from payload: [String: AnyCodable]) {
        guard let action = payload.string("action"),
              let task = payload.string("task"),
              let list = payload.string("list") else {
            return nil
        }
        self.action = action
        self.task = task
        self.list = list
    }
}

// MARK: - Metadata Payloads

/// Payload for metadata.update event
/// Server: MetadataUpdateEvent.payload
struct MetadataUpdatePayload {
    let key: String
    let previousValue: Any?
    let newValue: Any?

    init?(from payload: [String: AnyCodable]) {
        guard let key = payload.string("key") else {
            return nil
        }
        self.key = key
        self.previousValue = payload["previousValue"]?.value
        self.newValue = payload["newValue"]?.value
    }
}

/// Payload for metadata.tag event
/// Server: MetadataTagEvent.payload
struct MetadataTagPayload {
    let action: String  // "add" | "remove"
    let tag: String

    init?(from payload: [String: AnyCodable]) {
        guard let action = payload.string("action"),
              let tag = payload.string("tag") else {
            return nil
        }
        self.action = action
        self.tag = tag
    }
}

// MARK: - File Payloads

/// Payload for file.read event
/// Server: FileReadEvent.payload
struct FileReadPayload {
    let path: String
    let linesStart: Int?
    let linesEnd: Int?

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path") else {
            return nil
        }
        self.path = path

        if let lines = payload.dict("lines") {
            self.linesStart = lines["start"] as? Int
            self.linesEnd = lines["end"] as? Int
        } else {
            self.linesStart = nil
            self.linesEnd = nil
        }
    }
}

/// Payload for file.write event
/// Server: FileWriteEvent.payload
struct FileWritePayload {
    let path: String
    let size: Int
    let contentHash: String

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path"),
              let contentHash = payload.string("contentHash") else {
            return nil
        }
        self.path = path
        self.size = payload.int("size") ?? 0
        self.contentHash = contentHash
    }
}

/// Payload for file.edit event
/// Server: FileEditEvent.payload
struct FileEditPayload {
    let path: String
    let oldString: String
    let newString: String
    let diff: String?

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path"),
              let oldString = payload.string("oldString"),
              let newString = payload.string("newString") else {
            return nil
        }
        self.path = path
        self.oldString = oldString
        self.newString = newString
        self.diff = payload.string("diff")
    }
}

// MARK: - Compaction Payloads

/// Payload for compact.boundary event
/// Server: CompactBoundaryEvent.payload
struct CompactBoundaryPayload {
    let rangeFrom: String
    let rangeTo: String
    let originalTokens: Int
    let compactedTokens: Int

    init?(from payload: [String: AnyCodable]) {
        guard let range = payload.dict("range"),
              let from = range["from"] as? String,
              let to = range["to"] as? String else {
            return nil
        }
        self.rangeFrom = from
        self.rangeTo = to
        self.originalTokens = payload.int("originalTokens") ?? 0
        self.compactedTokens = payload.int("compactedTokens") ?? 0
    }
}

/// Payload for compact.summary event
/// Server: CompactSummaryEvent.payload
struct CompactSummaryPayload {
    let summary: String
    let keyDecisions: [String]?
    let filesModified: [String]?
    let boundaryEventId: String

    init?(from payload: [String: AnyCodable]) {
        guard let summary = payload.string("summary"),
              let boundaryEventId = payload.string("boundaryEventId") else {
            return nil
        }
        self.summary = summary
        self.boundaryEventId = boundaryEventId
        self.keyDecisions = payload.stringArray("keyDecisions")
        self.filesModified = payload.stringArray("filesModified")
    }
}

// MARK: - Worktree Payloads

/// Payload for worktree.acquired event
/// Server: WorktreeAcquiredEvent.payload
struct WorktreeAcquiredPayload {
    let path: String
    let branch: String
    let baseCommit: String
    let isolated: Bool
    let forkedFrom: ForkedFromInfo?

    struct ForkedFromInfo {
        let sessionId: String
        let commit: String
    }

    init?(from payload: [String: AnyCodable]) {
        guard let path = payload.string("path"),
              let branch = payload.string("branch"),
              let baseCommit = payload.string("baseCommit") else {
            return nil
        }
        self.path = path
        self.branch = branch
        self.baseCommit = baseCommit
        self.isolated = payload.bool("isolated") ?? false

        if let forked = payload.dict("forkedFrom") {
            self.forkedFrom = ForkedFromInfo(
                sessionId: forked["sessionId"] as? String ?? "",
                commit: forked["commit"] as? String ?? ""
            )
        } else {
            self.forkedFrom = nil
        }
    }
}

/// Payload for worktree.commit event
/// Server: WorktreeCommitEvent.payload
struct WorktreeCommitPayload {
    let commitHash: String
    let message: String
    let filesChanged: [String]
    let insertions: Int?
    let deletions: Int?

    init?(from payload: [String: AnyCodable]) {
        guard let commitHash = payload.string("commitHash"),
              let message = payload.string("message") else {
            return nil
        }
        self.commitHash = commitHash
        self.message = message
        self.filesChanged = payload.stringArray("filesChanged") ?? []
        self.insertions = payload.int("insertions")
        self.deletions = payload.int("deletions")
    }
}

/// Payload for worktree.released event
/// Server: WorktreeReleasedEvent.payload
struct WorktreeReleasedPayload {
    let finalCommit: String?
    let deleted: Bool
    let branchPreserved: Bool

    init(from payload: [String: AnyCodable]) {
        self.finalCommit = payload.string("finalCommit")
        self.deleted = payload.bool("deleted") ?? false
        self.branchPreserved = payload.bool("branchPreserved") ?? false
    }
}

/// Payload for worktree.merged event
/// Server: WorktreeMergedEvent.payload
struct WorktreeMergedPayload {
    let sourceBranch: String
    let targetBranch: String
    let mergeCommit: String
    let strategy: MergeStrategy?

    init?(from payload: [String: AnyCodable]) {
        guard let sourceBranch = payload.string("sourceBranch"),
              let targetBranch = payload.string("targetBranch"),
              let mergeCommit = payload.string("mergeCommit") else {
            return nil
        }
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.mergeCommit = mergeCommit

        if let strategyStr = payload.string("strategy") {
            self.strategy = MergeStrategy(rawValue: strategyStr)
        } else {
            self.strategy = nil
        }
    }
}

// MARK: - Stream Payloads (persisted streaming events)

/// Payload for stream.turn_end event
/// Server: StreamTurnEndEvent.payload
struct StreamTurnEndPayload {
    let turn: Int
    let tokenUsage: TokenUsage?

    init(from payload: [String: AnyCodable]) {
        self.turn = payload.int("turn") ?? 1

        if let usage = payload.dict("tokenUsage") {
            self.tokenUsage = TokenUsage(
                inputTokens: usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.tokenUsage = nil
        }
    }
}

// =============================================================================
// MARK: - Streaming RPC Event Payloads (from server core/src/rpc/types.ts)
// =============================================================================

// These payload structures EXACTLY mirror the server's RPC event data types.
// Each struct corresponds to a specific StreamingEventType.

/// Payload for agent.text_delta event
/// Server: AgentTextDeltaEvent
struct StreamingTextDeltaPayload {
    let delta: String
    let accumulated: String?

    init?(from data: [String: Any]) {
        guard let delta = data["delta"] as? String else { return nil }
        self.delta = delta
        self.accumulated = data["accumulated"] as? String
    }
}

/// Payload for agent.thinking_delta event
/// Server: AgentThinkingDeltaEvent
struct StreamingThinkingDeltaPayload {
    let delta: String

    init?(from data: [String: Any]) {
        guard let delta = data["delta"] as? String else { return nil }
        self.delta = delta
    }
}

/// Payload for agent.tool_start event
/// Server: AgentToolStartEvent
struct StreamingToolStartPayload {
    let toolCallId: String
    let toolName: String
    let arguments: String  // JSON string

    init?(from data: [String: Any]) {
        guard let toolCallId = data["toolCallId"] as? String,
              let toolName = data["toolName"] as? String else { return nil }

        self.toolCallId = toolCallId
        self.toolName = toolName

        if let argsDict = data["arguments"] as? [String: Any],
           let jsonData = try? JSONSerialization.data(withJSONObject: argsDict),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.arguments = jsonString
        } else {
            self.arguments = "{}"
        }
    }
}

/// Payload for agent.tool_end event
/// Server: AgentToolEndEvent
struct StreamingToolEndPayload {
    let toolCallId: String
    let toolName: String
    let durationMs: Int
    let success: Bool
    let output: String?
    let error: String?

    init?(from data: [String: Any]) {
        guard let toolCallId = data["toolCallId"] as? String,
              let toolName = data["toolName"] as? String else { return nil }

        self.toolCallId = toolCallId
        self.toolName = toolName
        self.durationMs = data["duration"] as? Int ?? 0
        self.success = data["success"] as? Bool ?? true
        self.output = data["output"] as? String
        self.error = data["error"] as? String
    }
}

/// Payload for agent.turn_start event
struct StreamingTurnStartPayload {
    let turn: Int

    init?(from data: [String: Any]) {
        guard let turn = data["turn"] as? Int ?? data["turnNumber"] as? Int else { return nil }
        self.turn = turn
    }
}

/// Payload for agent.turn_end event
struct StreamingTurnEndPayload {
    let turn: Int
    let tokenUsage: TokenUsage?
    let stopReason: String?
    let durationMs: Int?

    init?(from data: [String: Any]) {
        guard let turn = data["turn"] as? Int ?? data["turnNumber"] as? Int else { return nil }
        self.turn = turn

        if let usage = data["tokenUsage"] as? [String: Any] {
            self.tokenUsage = TokenUsage(
                inputTokens: usage["input"] as? Int ?? usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["output"] as? Int ?? usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.tokenUsage = nil
        }

        self.stopReason = data["stopReason"] as? String
        self.durationMs = data["duration"] as? Int
    }
}

/// Payload for agent.complete event
/// Server: AgentCompleteEvent
struct StreamingCompletePayload {
    let turns: Int
    let tokenUsage: TokenUsage?
    let success: Bool
    let error: String?

    init?(from data: [String: Any]) {
        self.turns = data["turns"] as? Int ?? 0
        self.success = data["success"] as? Bool ?? true
        self.error = data["error"] as? String

        if let usage = data["tokenUsage"] as? [String: Any] {
            self.tokenUsage = TokenUsage(
                inputTokens: usage["input"] as? Int ?? usage["inputTokens"] as? Int ?? 0,
                outputTokens: usage["output"] as? Int ?? usage["outputTokens"] as? Int ?? 0,
                cacheReadTokens: usage["cacheReadTokens"] as? Int,
                cacheCreationTokens: usage["cacheCreationTokens"] as? Int
            )
        } else {
            self.tokenUsage = nil
        }
    }
}

/// Payload for agent.error event
struct StreamingErrorPayload {
    let code: String?
    let message: String
    let error: String?

    init?(from data: [String: Any]) {
        guard let message = data["message"] as? String ?? data["error"] as? String else {
            return nil
        }
        self.message = message
        self.code = data["code"] as? String
        self.error = data["error"] as? String
    }
}
