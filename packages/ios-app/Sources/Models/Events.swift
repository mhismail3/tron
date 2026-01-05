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
        let output: String?  // Server sometimes sends 'output' instead of 'result'
        let error: String?
        let durationMs: Int?
        let duration: Int?   // Server sometimes sends 'duration' instead of 'durationMs'
    }

    var toolCallId: String { data.toolCallId }
    var toolName: String? { data.toolName }
    var success: Bool { data.success }
    var result: String? { data.result ?? data.output }  // Prefer result, fallback to output
    var error: String? { data.error }
    var durationMs: Int? { data.durationMs ?? data.duration }  // Handle both field names

    var displayResult: String {
        if data.success {
            // Prefer output over result for full content, never just say "Success"
            return data.output ?? data.result ?? ""
        } else {
            return data.error ?? "Error"
        }
    }
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
    }

    var turnNumber: Int { data?.turn ?? data?.turnNumber ?? 1 }
    var tokenUsage: TokenUsage? { data?.tokenUsage }
    var stopReason: String? { data?.stopReason }
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
    case connected = "connection.established"
    case systemConnected = "system.connected"
    case sessionCreated = "session.created"
    case sessionEnded = "session.ended"
    case agentTurn = "agent.turn"
}

// MARK: - Event Parsing

enum ParsedEvent {
    case textDelta(TextDeltaEvent)
    case thinkingDelta(ThinkingDeltaEvent)
    case toolStart(ToolStartEvent)
    case toolEnd(ToolEndEvent)
    case turnStart(TurnStartEvent)
    case turnEnd(TurnEndEvent)
    case complete(CompleteEvent)
    case error(ErrorEvent)
    case connected(ConnectedEvent)
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

            case EventType.connected.rawValue, EventType.systemConnected.rawValue:
                let event = try decoder.decode(ConnectedEvent.self, from: data)
                return .connected(event)

            case EventType.sessionCreated.rawValue, EventType.sessionEnded.rawValue, EventType.agentTurn.rawValue:
                // These are informational events we don't need to handle
                logger.debug("Ignoring informational event: \(type)", category: .events)
                return nil

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
