import Foundation

/// Plugin for handling long-running capability progress heartbeats.
/// Delivers optional status messages and completion fractions from any
/// capability invocation that emits progress.
enum CapabilityInvocationProgressPlugin: DispatchableEventPlugin {
    static let eventType = "capability.invocation.progress"

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
            let modelPrimitiveName: String?
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
        let invocationId: String
        let message: String?
        let percent: Double?
        let identity: CapabilityIdentity

        init(
            invocationId: String,
            message: String?,
            percent: Double?,
            identity: CapabilityIdentity? = nil
        ) {
            self.invocationId = invocationId
            self.message = message
            self.percent = percent
            self.identity = identity ?? CapabilityIdentity()
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
        context.handleCapabilityInvocationProgress(r)
    }
}
