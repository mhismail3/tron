import Foundation

// MARK: - Server Event Types

/// Represents all server-sent events via WebSocket
struct ServerEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?

    // We'll decode data separately based on type
    private enum CodingKeys: String, CodingKey {
        case type, sessionId, timestamp
    }
}

// MARK: - Event Data Types

struct TextDeltaEvent: Decodable {
    let type: String
    let sessionId: String?
    let delta: String
    let messageIndex: Int?
}

struct ThinkingDeltaEvent: Decodable {
    let type: String
    let sessionId: String?
    let delta: String
}

struct ToolStartEvent: Decodable {
    let type: String
    let sessionId: String?
    let toolName: String
    let toolCallId: String
    let arguments: [String: AnyCodable]?

    var formattedArguments: String {
        guard let args = arguments else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(args),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}

struct ToolEndEvent: Decodable {
    let type: String
    let sessionId: String?
    let toolCallId: String
    let success: Bool
    let result: String?
    let error: String?
    let durationMs: Int?

    var displayResult: String {
        if success {
            return result ?? "Success"
        } else {
            return error ?? "Error"
        }
    }
}

struct TurnStartEvent: Decodable {
    let type: String
    let sessionId: String?
    let turnNumber: Int
}

struct TurnEndEvent: Decodable {
    let type: String
    let sessionId: String?
    let turnNumber: Int
    let tokenUsage: TokenUsage?
    let stopReason: String?
}

struct CompleteEvent: Decodable {
    let type: String
    let sessionId: String?
    let totalTokens: TokenUsage?
    let totalTurns: Int?
}

struct ErrorEvent: Decodable {
    let type: String
    let sessionId: String?
    let code: String
    let message: String
}

struct ConnectedEvent: Decodable {
    let type: String
    let serverId: String?
    let version: String?
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
    case sessionCreated = "session.created"
    case sessionEnded = "session.ended"
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
            return nil
        }

        let decoder = JSONDecoder()

        switch type {
        case EventType.textDelta.rawValue:
            guard let event = try? decoder.decode(TextDeltaEvent.self, from: data) else { return nil }
            return .textDelta(event)

        case EventType.thinkingDelta.rawValue:
            guard let event = try? decoder.decode(ThinkingDeltaEvent.self, from: data) else { return nil }
            return .thinkingDelta(event)

        case EventType.toolStart.rawValue:
            guard let event = try? decoder.decode(ToolStartEvent.self, from: data) else { return nil }
            return .toolStart(event)

        case EventType.toolEnd.rawValue:
            guard let event = try? decoder.decode(ToolEndEvent.self, from: data) else { return nil }
            return .toolEnd(event)

        case EventType.turnStart.rawValue:
            guard let event = try? decoder.decode(TurnStartEvent.self, from: data) else { return nil }
            return .turnStart(event)

        case EventType.turnEnd.rawValue:
            guard let event = try? decoder.decode(TurnEndEvent.self, from: data) else { return nil }
            return .turnEnd(event)

        case EventType.complete.rawValue:
            guard let event = try? decoder.decode(CompleteEvent.self, from: data) else { return nil }
            return .complete(event)

        case EventType.error.rawValue:
            guard let event = try? decoder.decode(ErrorEvent.self, from: data) else { return nil }
            return .error(event)

        case EventType.connected.rawValue:
            guard let event = try? decoder.decode(ConnectedEvent.self, from: data) else { return nil }
            return .connected(event)

        default:
            return .unknown(type)
        }
    }
}
