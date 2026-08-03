import Foundation

/// Plugin for handling tool invocation generating events.
/// These events signal that the LLM has started generating a tool invocation,
/// BEFORE arguments are fully streamed. This allows the UI to show a
/// spinning chip immediately instead of waiting for tool execution.
enum ToolInvocationGeneratingPlugin: DispatchableEventPlugin {
    static let eventType = "tool.invocation.generating"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let toolName: String
            let invocationId: String
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
        let identity: ToolIdentity
        let timestamp: Date?

        init(
            toolName: String,
            invocationId: String,
            identity: ToolIdentity? = nil,
            timestamp: Date? = nil
        ) {
            self.toolName = toolName
            self.invocationId = invocationId
            self.identity = identity ?? ToolIdentity()
            self.timestamp = timestamp
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            toolName: event.data.toolName,
            invocationId: event.data.invocationId,
            identity: event.data.identity,
            timestamp: event.timestamp.flatMap(DateParser.parse)
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleToolInvocationGenerating(r)
    }
}
