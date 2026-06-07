import Foundation

/// Plugin for long-running capability handles such as background jobs.
enum CapabilityRunStatusPlugin: DispatchableEventPlugin {
    static let eventType = "capability.run.status"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let runId: String
            let invocationId: String
            let status: String
            let streamTopic: String?
            let childInvocations: [String]?
            let details: [String: AnyCodable]?
            let modelPrimitiveName: String?
            let operationName: String?
            let operation: String?
            let traceId: String?
            let rootInvocationId: String?
            let themeColor: String?
            let presentationHints: [String: AnyCodable]?

            var identity: CapabilityIdentity {
                CapabilityIdentity(
                    modelPrimitiveName: modelPrimitiveName,
                    operationName: operationName ?? operation,
                    traceId: traceId,
                    rootInvocationId: rootInvocationId,
                    themeColor: themeColor,
                    presentationHints: presentationHints
                )
            }
        }
    }

    struct Result: EventResult {
        let runId: String
        let invocationId: String
        let status: String
        let streamTopic: String?
        let childInvocations: [String]
        let details: [String: AnyCodable]?
        let identity: CapabilityIdentity
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            runId: event.data.runId,
            invocationId: event.data.invocationId,
            status: event.data.status,
            streamTopic: event.data.streamTopic,
            childInvocations: event.data.childInvocations ?? [],
            details: event.data.details,
            identity: event.data.identity
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCapabilityRunStatus(r)
    }
}
