import Foundation

/// Plugin for handling long-running tool progress heartbeats.
/// Delivers optional status messages and completion fractions from any
/// tool invocation that emits progress.
enum ToolInvocationProgressPlugin: DispatchableEventPlugin {
    static let eventType = "tool.invocation.progress"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let invocationId: String
            let message: String?
            let percent: Double?
            let toolName: String?
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
        let invocationId: String
        let message: String?
        let percent: Double?
        let identity: ToolIdentity

        init(
            invocationId: String,
            message: String?,
            percent: Double?,
            identity: ToolIdentity? = nil
        ) {
            self.invocationId = invocationId
            self.message = message
            self.percent = percent
            self.identity = identity ?? ToolIdentity()
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            invocationId: event.data.invocationId,
            message: event.data.message,
            percent: event.data.percent,
            identity: event.data.identity
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleToolInvocationProgress(r)
    }
}
