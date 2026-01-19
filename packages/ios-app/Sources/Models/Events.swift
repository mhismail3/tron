import Foundation

// MARK: - Server Event Types

/// Represents all server-sent events via WebSocket
/// Server format: { type, sessionId?, timestamp?, data: { ...payload } }
struct ServerEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
}

// MARK: - Event Data Types

struct TextDeltaEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: TextDeltaData

    struct TextDeltaData: Decodable {
        let delta: String
        let messageIndex: Int?
    }

    var delta: String { data.delta }
}

struct ThinkingDeltaEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: ThinkingDeltaData

    struct ThinkingDeltaData: Decodable {
        let delta: String
    }

    var delta: String { data.delta }
}

struct ToolStartEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: ToolStartData

    struct ToolStartData: Decodable {
        let toolName: String
        let toolCallId: String
        let arguments: [String: AnyCodable]?
    }

    var toolName: String { data.toolName }
    var toolCallId: String { data.toolCallId }
    var arguments: [String: AnyCodable]? { data.arguments }

    var formattedArguments: String {
        guard let args = data.arguments else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(args),
              let string = String(data: jsonData, encoding: .utf8) else {
            return ""
        }
        return string
    }
}

struct ToolEndEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: ToolEndData

    struct ToolEndData: Decodable {
        let toolCallId: String
        let toolName: String?
        let success: Bool
        let result: String?
        let output: String?  // Extracted from string or array format
        let error: String?
        let durationMs: Int?
        let duration: Int?
        let details: ToolDetails?  // Additional details like full screenshot data

        enum CodingKeys: String, CodingKey {
            case toolCallId, toolName, success, result, output, error, durationMs, duration, details
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            toolCallId = try container.decode(String.self, forKey: .toolCallId)
            toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
            success = try container.decode(Bool.self, forKey: .success)
            result = try container.decodeIfPresent(String.self, forKey: .result)
            error = try container.decodeIfPresent(String.self, forKey: .error)
            durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
            duration = try container.decodeIfPresent(Int.self, forKey: .duration)
            details = try container.decodeIfPresent(ToolDetails.self, forKey: .details)

            // Handle output as either String or [ContentBlock] array
            if let outputString = try? container.decodeIfPresent(String.self, forKey: .output) {
                output = outputString
            } else if let outputBlocks = try? container.decodeIfPresent([ToolOutputBlock].self, forKey: .output) {
                // Extract text from content blocks and join them
                output = outputBlocks.compactMap { $0.text }.joined()
            } else {
                output = nil
            }
        }
    }

    /// Details structure for tool results (e.g., screenshot data)
    struct ToolDetails: Decodable {
        let screenshot: String?  // Full base64 screenshot data
        let format: String?      // Image format (png, jpeg)
    }

    var toolCallId: String { data.toolCallId }
    var toolName: String? { data.toolName }
    var success: Bool { data.success }
    var result: String? { data.result ?? data.output }  // Prefer result, fallback to output
    var error: String? { data.error }
    var durationMs: Int? { data.durationMs ?? data.duration }  // Handle both field names
    var details: ToolDetails? { data.details }  // Access to full binary data (e.g., screenshots)

    var displayResult: String {
        if data.success {
            // Prefer output over result for full content, never just say "Success"
            return data.output ?? data.result ?? ""
        } else {
            return data.error ?? "Error"
        }
    }
}

/// Helper struct for decoding tool output content blocks
/// Server may send output as [{"type":"text","text":"..."}]
private struct ToolOutputBlock: Decodable {
    let type: String
    let text: String?
}

struct TurnStartEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: TurnStartData?

    struct TurnStartData: Decodable {
        let turn: Int?
        let turnNumber: Int?

        // Handle both "turn" and "turnNumber" from server
        var number: Int { turn ?? turnNumber ?? 1 }
    }

    var turnNumber: Int { data?.number ?? 1 }
}

struct TurnEndEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: TurnEndData?

    struct TurnEndData: Decodable {
        let turn: Int?
        let turnNumber: Int?
        let duration: Int?
        let tokenUsage: TokenUsage?
        let stopReason: String?
        let cost: Double?
        /// Current model's context window limit (for syncing iOS state after model switch)
        let contextLimit: Int?

        enum CodingKeys: String, CodingKey {
            case turn, turnNumber, duration, tokenUsage, stopReason, cost, contextLimit
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            turn = try container.decodeIfPresent(Int.self, forKey: .turn)
            turnNumber = try container.decodeIfPresent(Int.self, forKey: .turnNumber)
            duration = try container.decodeIfPresent(Int.self, forKey: .duration)
            tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
            stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
            contextLimit = try container.decodeIfPresent(Int.self, forKey: .contextLimit)

            // Handle cost as either Double or String
            if let costDouble = try? container.decodeIfPresent(Double.self, forKey: .cost) {
                cost = costDouble
            } else if let costString = try? container.decodeIfPresent(String.self, forKey: .cost),
                      let costValue = Double(costString) {
                cost = costValue
            } else {
                cost = nil
            }
        }
    }

    var turnNumber: Int { data?.turn ?? data?.turnNumber ?? 1 }
    var tokenUsage: TokenUsage? { data?.tokenUsage }
    var stopReason: String? { data?.stopReason }
    var cost: Double? { data?.cost }
    /// Current model's context window limit
    var contextLimit: Int? { data?.contextLimit }
}

struct CompleteEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: CompleteData?

    struct CompleteData: Decodable {
        let success: Bool?
        let totalTokens: TokenUsage?
        let totalTurns: Int?
    }

    var totalTokens: TokenUsage? { data?.totalTokens }
    var totalTurns: Int? { data?.totalTurns }
}

/// Agent turn event containing full message history with tool content blocks
struct AgentTurnEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: AgentTurnData

    struct AgentTurnData: Decodable {
        let messages: [TurnMessage]
        let turn: Int?
        let turnNumber: Int?
    }

    struct TurnMessage: Decodable {
        let role: String
        let content: TurnContent

        enum CodingKeys: String, CodingKey {
            case role, content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)

            // Content can be a string OR an array of content blocks
            if let stringContent = try? container.decode(String.self, forKey: .content) {
                content = .text(stringContent)
            } else if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                content = .blocks(blocks)
            } else {
                content = .text("")
            }
        }
    }

    enum TurnContent {
        case text(String)
        case blocks([ContentBlock])

        var textContent: String? {
            switch self {
            case .text(let str): return str
            case .blocks(let blocks):
                return blocks.compactMap { block -> String? in
                    if case .text(let text) = block { return text }
                    return nil
                }.joined()
            }
        }

        var allBlocks: [ContentBlock] {
            switch self {
            case .text(let str): return [.text(str)]
            case .blocks(let blocks): return blocks
            }
        }
    }

    enum ContentBlock: Decodable {
        case text(String)
        case toolUse(id: String, name: String, input: [String: AnyCodable])
        case toolResult(toolUseId: String, content: String, isError: Bool)
        case thinking(text: String)
        case unknown

        enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, toolUseId = "tool_use_id", content, isError = "is_error", thinking
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)

            case "tool_use":
                let id = try container.decode(String.self, forKey: .id)
                let name = try container.decode(String.self, forKey: .name)
                let input = try container.decodeIfPresent([String: AnyCodable].self, forKey: .input) ?? [:]
                self = .toolUse(id: id, name: name, input: input)

            case "tool_result":
                let toolUseId = try container.decode(String.self, forKey: .toolUseId)
                // Content can be string or array
                let content: String
                if let str = try? container.decode(String.self, forKey: .content) {
                    content = str
                } else if let arr = try? container.decode([ContentPart].self, forKey: .content) {
                    content = arr.compactMap { $0.text }.joined()
                } else {
                    content = ""
                }
                let isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
                self = .toolResult(toolUseId: toolUseId, content: content, isError: isError)

            case "thinking":
                let text = try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""
                self = .thinking(text: text)

            default:
                self = .unknown
            }
        }

        struct ContentPart: Decodable {
            let type: String?
            let text: String?
        }
    }

    var messages: [TurnMessage] { data.messages }
    var turnNumber: Int { data.turn ?? data.turnNumber ?? 1 }

    /// Extract all tool uses from assistant messages
    var toolUses: [(id: String, name: String, input: [String: AnyCodable])] {
        messages.filter { $0.role == "assistant" }.flatMap { msg -> [(id: String, name: String, input: [String: AnyCodable])] in
            msg.content.allBlocks.compactMap { block in
                if case .toolUse(let id, let name, let input) = block {
                    return (id, name, input)
                }
                return nil
            }
        }
    }

    /// Extract all tool results from user messages
    var toolResults: [(toolUseId: String, content: String, isError: Bool)] {
        messages.filter { $0.role == "user" }.flatMap { msg -> [(toolUseId: String, content: String, isError: Bool)] in
            msg.content.allBlocks.compactMap { block in
                if case .toolResult(let toolUseId, let content, let isError) = block {
                    return (toolUseId, content, isError)
                }
                return nil
            }
        }
    }
}

struct ErrorEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: ErrorData?

    struct ErrorData: Decodable {
        let code: String?
        let message: String?
        let error: String?
    }

    var code: String { data?.code ?? "UNKNOWN" }
    var message: String { data?.message ?? data?.error ?? "Unknown error" }
}

struct CompactionEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: CompactionData

    struct CompactionData: Decodable {
        let tokensBefore: Int
        let tokensAfter: Int
        let compressionRatio: Double?
        let reason: String?
        let summary: String?
    }

    var tokensBefore: Int { data.tokensBefore }
    var tokensAfter: Int { data.tokensAfter }
    var compressionRatio: Double { data.compressionRatio ?? Double(data.tokensAfter) / Double(data.tokensBefore) }
    var reason: String { data.reason ?? "auto" }
    var summary: String? { data.summary }
}

struct ContextClearedEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: ContextClearedData

    struct ContextClearedData: Decodable {
        let tokensBefore: Int
        let tokensAfter: Int
    }

    var tokensBefore: Int { data.tokensBefore }
    var tokensAfter: Int { data.tokensAfter }
}

struct MessageDeletedEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: MessageDeletedData

    struct MessageDeletedData: Decodable {
        let targetEventId: String
        let targetType: String
        let targetTurn: Int?
        let reason: String?
    }

    var targetEventId: String { data.targetEventId }
    var targetType: String { data.targetType }
    var targetTurn: Int? { data.targetTurn }
    var reason: String? { data.reason }
}

struct ConnectedEvent: Decodable {
    let type: String
    let timestamp: String?
    let data: ConnectedData?

    struct ConnectedData: Decodable {
        let clientId: String?
        let serverId: String?
        let version: String?
    }

    var serverId: String? { data?.serverId }
    var version: String? { data?.version }
    var clientId: String? { data?.clientId }
}

struct SkillRemovedEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: SkillRemovedData

    struct SkillRemovedData: Decodable {
        let skillName: String
    }

    var skillName: String { data.skillName }
}

// MARK: - Subagent Events (real-time WebSocket updates for iOS)

/// Event fired when a subagent is spawned
struct SubagentSpawnedEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: SubagentSpawnedData

    struct SubagentSpawnedData: Decodable {
        let subagentSessionId: String
        let task: String
        let model: String?
        let workingDirectory: String?
        let toolCallId: String?
    }

    var subagentSessionId: String { data.subagentSessionId }
    var task: String { data.task }
    var model: String? { data.model }
    var workingDirectory: String? { data.workingDirectory }
    var toolCallId: String? { data.toolCallId }
}

/// Event fired when a subagent's status updates
struct SubagentStatusEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: SubagentStatusData

    struct SubagentStatusData: Decodable {
        let subagentSessionId: String
        let status: String
        let currentTurn: Int
    }

    var subagentSessionId: String { data.subagentSessionId }
    var status: String { data.status }
    var currentTurn: Int { data.currentTurn }
}

/// Event fired when a subagent completes successfully
struct SubagentCompletedEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: SubagentCompletedData

    struct SubagentCompletedData: Decodable {
        let subagentSessionId: String
        let resultSummary: String
        let fullOutput: String?
        let totalTurns: Int
        let duration: Int
        let tokenUsage: TokenUsage?
    }

    var subagentSessionId: String { data.subagentSessionId }
    var resultSummary: String { data.resultSummary }
    var fullOutput: String? { data.fullOutput }
    var totalTurns: Int { data.totalTurns }
    var duration: Int { data.duration }
    var tokenUsage: TokenUsage? { data.tokenUsage }
}

/// Event fired when a subagent fails
struct SubagentFailedEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: SubagentFailedData

    struct SubagentFailedData: Decodable {
        let subagentSessionId: String
        let error: String
        let duration: Int
    }

    var subagentSessionId: String { data.subagentSessionId }
    var error: String { data.error }
    var duration: Int { data.duration }
}

/// Event fired when a subagent's internal event is forwarded to parent (for real-time detail sheet)
struct SubagentForwardedEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: SubagentForwardedData

    struct SubagentForwardedData: Decodable {
        let subagentSessionId: String
        let event: InnerEvent
    }

    struct InnerEvent: Decodable {
        let type: String
        let data: AnyCodable
        let timestamp: String
    }

    var subagentSessionId: String { data.subagentSessionId }
    var event: InnerEvent { data.event }
}

// MARK: - Plan Mode Events

/// Event fired when plan mode is entered (read-only enforcement begins)
struct PlanModeEnteredEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: PlanModeEnteredData

    struct PlanModeEnteredData: Decodable {
        let skillName: String
        let blockedTools: [String]
    }

    var skillName: String { data.skillName }
    var blockedTools: [String] { data.blockedTools }
}

/// Event fired when plan mode is exited (read-only enforcement ends)
struct PlanModeExitedEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: PlanModeExitedData

    struct PlanModeExitedData: Decodable {
        let reason: String  // "approved", "cancelled", "timeout"
        let planPath: String?
    }

    var reason: String { data.reason }
    var planPath: String? { data.planPath }
}

// MARK: - UI Canvas Events (RenderAppUI tool)

/// Event fired when UI canvas rendering starts
struct UIRenderStartEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: UIRenderStartData

    struct UIRenderStartData: Decodable {
        let canvasId: String
        let title: String?
        let toolCallId: String
    }

    var canvasId: String { data.canvasId }
    var title: String? { data.title }
    var toolCallId: String { data.toolCallId }
}

/// Event fired during progressive UI render with JSON chunks
struct UIRenderChunkEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: UIRenderChunkData

    struct UIRenderChunkData: Decodable {
        let canvasId: String
        let chunk: String
        let accumulated: String
    }

    var canvasId: String { data.canvasId }
    var chunk: String { data.chunk }
    var accumulated: String { data.accumulated }
}

/// Event fired when UI canvas rendering completes
struct UIRenderCompleteEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: UIRenderCompleteData

    struct UIRenderCompleteData: Decodable {
        let canvasId: String
        let ui: [String: AnyCodable]?
        let state: [String: AnyCodable]?
    }

    var canvasId: String { data.canvasId }
    var ui: [String: AnyCodable]? { data.ui }
    var state: [String: AnyCodable]? { data.state }
}

/// UI Render Error Event - validation or parsing error
struct UIRenderErrorEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: UIRenderErrorData

    struct UIRenderErrorData: Decodable {
        let canvasId: String
        let error: String
    }

    var canvasId: String { data.canvasId }
    var error: String { data.error }
}

/// UI Render Retry Event - validation failed, agent will retry automatically
struct UIRenderRetryEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: UIRenderRetryData

    struct UIRenderRetryData: Decodable {
        let canvasId: String
        let attempt: Int
        let errors: String
    }

    var canvasId: String { data.canvasId }
    var attempt: Int { data.attempt }
    var errors: String { data.errors }
}

// MARK: - Event Type Constants

enum EventType: String {
    case textDelta = "agent.text_delta"
    case thinkingDelta = "agent.thinking_delta"
    case toolStart = "agent.tool_start"
    case toolEnd = "agent.tool_end"
    case turnStart = "agent.turn_start"
    case turnEnd = "agent.turn_end"
    case complete = "agent.complete"
    case error = "agent.error"
    case compaction = "agent.compaction"
    case contextCleared = "agent.context_cleared"
    case messageDeleted = "agent.message_deleted"
    case skillRemoved = "agent.skill_removed"
    case planModeEntered = "plan.mode_entered"
    case planModeExited = "plan.mode_exited"
    case connected = "connection.established"
    case systemConnected = "system.connected"
    case sessionCreated = "session.created"
    case sessionEnded = "session.ended"
    case agentTurn = "agent.turn"
    // Subagent events
    case subagentSpawned = "agent.subagent_spawned"
    case subagentStatus = "agent.subagent_status"
    case subagentCompleted = "agent.subagent_completed"
    case subagentFailed = "agent.subagent_failed"
    case subagentEvent = "agent.subagent_event"  // Forwarded event from subagent
    // UI Canvas events
    case uiRenderStart = "agent.ui_render_start"
    case uiRenderChunk = "agent.ui_render_chunk"
    case uiRenderComplete = "agent.ui_render_complete"
    case uiRenderError = "agent.ui_render_error"
    case uiRenderRetry = "agent.ui_render_retry"
}

// MARK: - Event Parsing

enum ParsedEvent {
    case textDelta(TextDeltaEvent)
    case thinkingDelta(ThinkingDeltaEvent)
    case toolStart(ToolStartEvent)
    case toolEnd(ToolEndEvent)
    case turnStart(TurnStartEvent)
    case turnEnd(TurnEndEvent)
    case agentTurn(AgentTurnEvent)
    case complete(CompleteEvent)
    case error(ErrorEvent)
    case compaction(CompactionEvent)
    case contextCleared(ContextClearedEvent)
    case messageDeleted(MessageDeletedEvent)
    case skillRemoved(SkillRemovedEvent)
    case planModeEntered(PlanModeEnteredEvent)
    case planModeExited(PlanModeExitedEvent)
    case browserFrame(BrowserFrameEvent)
    case browserClosed(String)
    case connected(ConnectedEvent)
    // Subagent events
    case subagentSpawned(SubagentSpawnedEvent)
    case subagentStatus(SubagentStatusEvent)
    case subagentCompleted(SubagentCompletedEvent)
    case subagentFailed(SubagentFailedEvent)
    case subagentEvent(SubagentForwardedEvent)  // Forwarded event from subagent
    // UI Canvas events
    case uiRenderStart(UIRenderStartEvent)
    case uiRenderChunk(UIRenderChunkEvent)
    case uiRenderComplete(UIRenderCompleteEvent)
    case uiRenderError(UIRenderErrorEvent)
    case uiRenderRetry(UIRenderRetryEvent)
    case unknown(String)

    static func parse(from data: Data) -> ParsedEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            logger.warning("Failed to extract event type from data", category: .events)
            return nil
        }

        let decoder = JSONDecoder()

        do {
            switch type {
            case EventType.textDelta.rawValue:
                let event = try decoder.decode(TextDeltaEvent.self, from: data)
                return .textDelta(event)

            case EventType.thinkingDelta.rawValue:
                let event = try decoder.decode(ThinkingDeltaEvent.self, from: data)
                return .thinkingDelta(event)

            case EventType.toolStart.rawValue:
                let event = try decoder.decode(ToolStartEvent.self, from: data)
                return .toolStart(event)

            case EventType.toolEnd.rawValue:
                let event = try decoder.decode(ToolEndEvent.self, from: data)
                return .toolEnd(event)

            case EventType.turnStart.rawValue:
                let event = try decoder.decode(TurnStartEvent.self, from: data)
                return .turnStart(event)

            case EventType.turnEnd.rawValue:
                let event = try decoder.decode(TurnEndEvent.self, from: data)
                return .turnEnd(event)

            case EventType.complete.rawValue:
                let event = try decoder.decode(CompleteEvent.self, from: data)
                return .complete(event)

            case EventType.error.rawValue:
                let event = try decoder.decode(ErrorEvent.self, from: data)
                return .error(event)

            case EventType.compaction.rawValue:
                let event = try decoder.decode(CompactionEvent.self, from: data)
                logger.info("Context compacted: \(event.tokensBefore) -> \(event.tokensAfter) tokens (\(event.reason))", category: .events)
                return .compaction(event)

            case EventType.contextCleared.rawValue:
                let event = try decoder.decode(ContextClearedEvent.self, from: data)
                logger.info("Context cleared: \(event.tokensBefore) -> \(event.tokensAfter) tokens", category: .events)
                return .contextCleared(event)

            case EventType.messageDeleted.rawValue:
                let event = try decoder.decode(MessageDeletedEvent.self, from: data)
                logger.info("Message deleted: targetType=\(event.targetType), eventId=\(event.targetEventId)", category: .events)
                return .messageDeleted(event)

            case EventType.skillRemoved.rawValue:
                let event = try decoder.decode(SkillRemovedEvent.self, from: data)
                logger.info("Skill removed: \(event.skillName)", category: .events)
                return .skillRemoved(event)

            case EventType.planModeEntered.rawValue:
                let event = try decoder.decode(PlanModeEnteredEvent.self, from: data)
                logger.info("Plan mode entered: skill=\(event.skillName), blocked=\(event.blockedTools.joined(separator: ", "))", category: .events)
                return .planModeEntered(event)

            case EventType.planModeExited.rawValue:
                let event = try decoder.decode(PlanModeExitedEvent.self, from: data)
                logger.info("Plan mode exited: reason=\(event.reason)", category: .events)
                return .planModeExited(event)

            case "browser.frame":
                let event = try decoder.decode(BrowserFrameEvent.self, from: data)
                return .browserFrame(event)

            case "browser.closed":
                if let sessionId = json["sessionId"] as? String {
                    return .browserClosed(sessionId)
                }
                return nil

            case EventType.connected.rawValue, EventType.systemConnected.rawValue:
                let event = try decoder.decode(ConnectedEvent.self, from: data)
                return .connected(event)

            case EventType.agentTurn.rawValue:
                let event = try decoder.decode(AgentTurnEvent.self, from: data)
                logger.debug("Parsed agent.turn with \(event.messages.count) messages, \(event.toolUses.count) tool uses", category: .events)
                return .agentTurn(event)

            case EventType.sessionCreated.rawValue, EventType.sessionEnded.rawValue:
                // These are informational events we don't need to handle
                logger.debug("Ignoring informational event: \(type)", category: .events)
                return nil

            // Subagent events
            case EventType.subagentSpawned.rawValue:
                let event = try decoder.decode(SubagentSpawnedEvent.self, from: data)
                logger.info("Subagent spawned: \(event.subagentSessionId)", category: .events)
                return .subagentSpawned(event)

            case EventType.subagentStatus.rawValue:
                let event = try decoder.decode(SubagentStatusEvent.self, from: data)
                logger.debug("Subagent status: \(event.subagentSessionId) - \(event.status) turn \(event.currentTurn)", category: .events)
                return .subagentStatus(event)

            case EventType.subagentCompleted.rawValue:
                let event = try decoder.decode(SubagentCompletedEvent.self, from: data)
                logger.info("Subagent completed: \(event.subagentSessionId) in \(event.totalTurns) turns", category: .events)
                return .subagentCompleted(event)

            case EventType.subagentFailed.rawValue:
                let event = try decoder.decode(SubagentFailedEvent.self, from: data)
                logger.error("Subagent failed: \(event.subagentSessionId) - \(event.error)", category: .events)
                return .subagentFailed(event)

            case EventType.subagentEvent.rawValue:
                let event = try decoder.decode(SubagentForwardedEvent.self, from: data)
                logger.debug("Subagent event forwarded: \(event.subagentSessionId) - \(event.event.type)", category: .events)
                return .subagentEvent(event)

            // UI Canvas events
            case EventType.uiRenderStart.rawValue:
                let event = try decoder.decode(UIRenderStartEvent.self, from: data)
                logger.info("UI render start: \(event.canvasId)", category: .events)
                return .uiRenderStart(event)

            case EventType.uiRenderChunk.rawValue:
                let event = try decoder.decode(UIRenderChunkEvent.self, from: data)
                logger.debug("UI render chunk: \(event.canvasId)", category: .events)
                return .uiRenderChunk(event)

            case EventType.uiRenderComplete.rawValue:
                let event = try decoder.decode(UIRenderCompleteEvent.self, from: data)
                logger.info("UI render complete: \(event.canvasId)", category: .events)
                return .uiRenderComplete(event)

            case EventType.uiRenderError.rawValue:
                let event = try decoder.decode(UIRenderErrorEvent.self, from: data)
                logger.warning("UI render error: \(event.canvasId) - \(event.error)", category: .events)
                return .uiRenderError(event)

            case EventType.uiRenderRetry.rawValue:
                let event = try decoder.decode(UIRenderRetryEvent.self, from: data)
                logger.info("UI render retry: \(event.canvasId) attempt \(event.attempt)", category: .events)
                return .uiRenderRetry(event)

            default:
                logger.debug("Unknown event type: \(type)", category: .events)
                return .unknown(type)
            }
        } catch {
            logger.error("Failed to decode \(type) event: \(error.localizedDescription)", category: .events)
            // Log the raw JSON for debugging
            if let jsonStr = String(data: data, encoding: .utf8) {
                logger.debug("Raw event JSON: \(jsonStr.prefix(500))", category: .events)
            }
            return nil
        }
    }
}
