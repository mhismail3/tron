import Foundation

/// Plugin for a generic capability pause: user input and future plugin-defined
/// pauses flow through this event.
enum CapabilityPauseRequestedPlugin: DispatchableEventPlugin {
    static let eventType = "capability.pause.requested"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let pauseId: String
            let invocationId: String
            let kind: String
            let status: String
            let promptPayload: [String: AnyCodable]?
            let resumeSchema: AnyCodable?
            let answerAuthority: String?
            let expiresAt: String?
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
        let pauseId: String
        let invocationId: String
        let kind: String
        let status: String
        let promptPayload: [String: AnyCodable]?
        let resumeSchema: AnyCodable?
        let answerAuthority: String?
        let expiresAt: String?
        let identity: CapabilityIdentity
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            pauseId: event.data.pauseId,
            invocationId: event.data.invocationId,
            kind: event.data.kind,
            status: event.data.status,
            promptPayload: event.data.promptPayload,
            resumeSchema: event.data.resumeSchema,
            answerAuthority: event.data.answerAuthority,
            expiresAt: event.data.expiresAt,
            identity: event.data.identity
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCapabilityPauseRequested(r)
    }
}

/// Plugin for a generic capability pause resolution.
enum CapabilityPauseResolvedPlugin: DispatchableEventPlugin {
    static let eventType = "capability.pause.resolved"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let pauseId: String
            let invocationId: String
            let status: String
            let resolution: [String: AnyCodable]?
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
        let pauseId: String
        let invocationId: String
        let status: String
        let resolution: [String: AnyCodable]?
        let identity: CapabilityIdentity
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            pauseId: event.data.pauseId,
            invocationId: event.data.invocationId,
            status: event.data.status,
            resolution: event.data.resolution,
            identity: event.data.identity
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCapabilityPauseResolved(r)
    }
}

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
