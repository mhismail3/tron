import Foundation

/// Plugin for handling capability invocation generating events.
/// These events signal that the LLM has started generating a capability invocation,
/// BEFORE arguments are fully streamed. This allows the UI to show a
/// spinning chip immediately instead of waiting for capability execution.
enum CapabilityInvocationGeneratingPlugin: DispatchableEventPlugin {
    static let eventType = "capability.invocation.generating"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let modelPrimitiveName: String
            let invocationId: String
            let contractId: String?
            let implementationId: String?
            let functionId: String?
            let pluginId: String?
            let workerId: String?
            let schemaDigest: String?
            let catalogRevision: UInt64?
            let trustTier: String?
            let riskLevel: String?
            let effectClass: String?
            let traceId: String?
            let rootInvocationId: String?
            let bindingDecisionId: String?
            let themeColor: String?

            var identity: CapabilityIdentity {
                CapabilityIdentity(
                    modelPrimitiveName: modelPrimitiveName,
                    contractId: contractId,
                    implementationId: implementationId,
                    functionId: functionId,
                    pluginId: pluginId,
                    workerId: workerId,
                    schemaDigest: schemaDigest,
                    catalogRevision: catalogRevision,
                    trustTier: trustTier,
                    riskLevel: riskLevel,
                    effectClass: effectClass,
                    traceId: traceId,
                    rootInvocationId: rootInvocationId,
                    bindingDecisionId: bindingDecisionId,
                    themeColor: themeColor
                )
            }
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let modelPrimitiveName: String
        let invocationId: String
        let identity: CapabilityIdentity
        let timestamp: Date?

        init(
            modelPrimitiveName: String,
            invocationId: String,
            identity: CapabilityIdentity? = nil,
            timestamp: Date? = nil
        ) {
            self.modelPrimitiveName = modelPrimitiveName
            self.invocationId = invocationId
            self.identity = identity ?? CapabilityIdentity()
            self.timestamp = timestamp
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            modelPrimitiveName: event.data.modelPrimitiveName,
            invocationId: event.data.invocationId,
            identity: event.data.identity,
            timestamp: event.timestamp.flatMap(DateParser.parse)
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCapabilityInvocationGenerating(r)
    }
}
