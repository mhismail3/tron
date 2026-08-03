import Foundation

/// Plugin for handling tool invocation start events.
/// These events signal the beginning of a tool invocation.
enum ToolInvocationStartedPlugin: DispatchableEventPlugin {
    static let eventType = "tool.invocation.started"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let toolName: String
            let invocationId: String
            let arguments: [String: AnyCodable]?
            let traceId: String?
            let rootInvocationId: String?
            let themeColor: String?
            let presentationHints: [String: AnyCodable]?

            var identity: ToolIdentity {
                ToolIdentity(
                    toolName: toolName,
                    traceId: traceId,
                    rootInvocationId: rootInvocationId,
                    themeColor: themeColor,
                    presentationHints: presentationHints
                )
            }
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let toolName: String
        let invocationId: String
        let arguments: [String: AnyCodable]?
        let identity: ToolIdentity
        let timestamp: Date?

        init(
            toolName: String,
            invocationId: String,
            arguments: [String: AnyCodable]?,
            identity: ToolIdentity? = nil,
            timestamp: Date? = nil
        ) {
            self.toolName = toolName
            self.invocationId = invocationId
            self.arguments = arguments
            self.identity = identity ?? ToolIdentity()
            self.timestamp = timestamp
        }

        var formattedArguments: String {
            guard let args = arguments else { return "" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                let jsonData = try encoder.encode(args)
                return String(data: jsonData, encoding: .utf8) ?? ""
            } catch {
                logger.warning("Failed to format tool arguments for \(toolName): \(error.localizedDescription)", category: .events)
                return ""
            }
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            toolName: event.data.toolName,
            invocationId: event.data.invocationId,
            arguments: event.data.arguments,
            identity: event.data.identity,
            timestamp: event.timestamp.flatMap(DateParser.parse)
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleToolInvocationStarted(r)
    }
}
