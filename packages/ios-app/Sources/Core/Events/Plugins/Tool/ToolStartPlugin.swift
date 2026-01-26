import Foundation

/// Plugin for handling tool start events.
/// These events signal the beginning of a tool invocation.
enum ToolStartPlugin: EventPlugin {
    static let eventType = "agent.tool_start"

    // MARK: - Event Data

    struct EventData: Decodable, Sendable {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let toolName: String
            let toolCallId: String
            let arguments: [String: AnyCodable]?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let toolName: String
        let toolCallId: String
        let arguments: [String: AnyCodable]?

        var formattedArguments: String {
            guard let args = arguments else { return "" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let jsonData = try? encoder.encode(args),
                  let string = String(data: jsonData, encoding: .utf8) else {
                return ""
            }
            return string
        }
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            toolName: event.data.toolName,
            toolCallId: event.data.toolCallId,
            arguments: event.data.arguments
        )
    }
}
