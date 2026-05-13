import Foundation

/// Plugin for handling capability invocation completion events.
/// These events signal the completion of a capability invocation with results.
///
/// Note: Uses custom parsing to handle output as either String or [ContentBlock] array.
enum CapabilityInvocationCompletedPlugin: DispatchableEventPlugin {
    static let eventType = "capability.invocation.completed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let invocationId: String
            let modelPrimitiveName: String?
            let success: Bool
            let output: String?
            let error: String?
            let duration: Int?
            let details: CapabilityResultDetails?
            /// Raw details dictionary for capability-specific structured results
            let rawDetails: [String: AnyCodable]?
            let identity: CapabilityIdentity

            enum CodingKeys: String, CodingKey {
                case invocationId, modelPrimitiveName, success, output, error, duration, details
                case contractId, implementationId, functionId, pluginId, workerId
                case schemaDigest, catalogRevision, trustTier, riskLevel, effectClass, traceId
                case rootInvocationId, bindingDecisionId
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                invocationId = try container.decode(String.self, forKey: .invocationId)
                modelPrimitiveName = try container.decodeIfPresent(String.self, forKey: .modelPrimitiveName)
                success = try container.decode(Bool.self, forKey: .success)
                error = try container.decodeIfPresent(String.self, forKey: .error)
                duration = try container.decodeIfPresent(Int.self, forKey: .duration)
                details = try container.decodeIfPresent(CapabilityResultDetails.self, forKey: .details)
                rawDetails = try container.decodeIfPresent([String: AnyCodable].self, forKey: .details)
                identity = CapabilityIdentity(
                    modelPrimitiveName: try container.decodeIfPresent(String.self, forKey: .modelPrimitiveName),
                    contractId: try container.decodeIfPresent(String.self, forKey: .contractId),
                    implementationId: try container.decodeIfPresent(String.self, forKey: .implementationId),
                    functionId: try container.decodeIfPresent(String.self, forKey: .functionId),
                    pluginId: try container.decodeIfPresent(String.self, forKey: .pluginId),
                    workerId: try container.decodeIfPresent(String.self, forKey: .workerId),
                    schemaDigest: try container.decodeIfPresent(String.self, forKey: .schemaDigest),
                    catalogRevision: try container.decodeIfPresent(UInt64.self, forKey: .catalogRevision),
                    trustTier: try container.decodeIfPresent(String.self, forKey: .trustTier),
                    riskLevel: try container.decodeIfPresent(String.self, forKey: .riskLevel),
                    effectClass: try container.decodeIfPresent(String.self, forKey: .effectClass),
                    traceId: try container.decodeIfPresent(String.self, forKey: .traceId),
                    rootInvocationId: try container.decodeIfPresent(String.self, forKey: .rootInvocationId),
                    bindingDecisionId: try container.decodeIfPresent(String.self, forKey: .bindingDecisionId)
                )

                // Handle output as either String or [ContentBlock] array
                if let outputString = try? container.decodeIfPresent(String.self, forKey: .output) {
                    output = outputString
                } else if let outputBlocks = try? container.decodeIfPresent([CapabilityOutputBlock].self, forKey: .output) {
                    output = outputBlocks.compactMap { $0.text }.joined()
                } else {
                    output = nil
                }
            }
        }

        /// Details structure for capability results (e.g., screenshot data).
        struct CapabilityResultDetails: Decodable, Sendable {
            let screenshot: String?
            let format: String?
        }
    }

    /// Helper struct for decoding capability output content blocks.
    private struct CapabilityOutputBlock: Decodable {
        let type: String
        let text: String?
    }

    // MARK: - Result

    struct Result: EventResult {
        let invocationId: String
        let modelPrimitiveName: String?
        let success: Bool
        let output: String?
        let error: String?
        let duration: Int?
        let details: EventData.CapabilityResultDetails?
        /// Raw details dictionary for capability-specific structured results
        let rawDetails: [String: AnyCodable]?
        let identity: CapabilityIdentity

        init(
            invocationId: String,
            modelPrimitiveName: String?,
            success: Bool,
            output: String?,
            error: String?,
            duration: Int?,
            details: EventData.CapabilityResultDetails?,
            rawDetails: [String: AnyCodable]?,
            identity: CapabilityIdentity? = nil
        ) {
            self.invocationId = invocationId
            self.modelPrimitiveName = modelPrimitiveName
            self.success = success
            self.output = output
            self.error = error
            self.duration = duration
            self.details = details
            self.rawDetails = rawDetails
            self.identity = identity ?? CapabilityIdentity()
        }

        /// Display-friendly result text.
        var displayResult: String {
            if success {
                return output ?? ""
            } else {
                return error ?? "Error"
            }
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            invocationId: event.data.invocationId,
            modelPrimitiveName: event.data.modelPrimitiveName,
            success: event.data.success,
            output: event.data.output,
            error: event.data.error,
            duration: event.data.duration,
            details: event.data.details,
            rawDetails: event.data.rawDetails,
            identity: event.data.identity
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCapabilityInvocationCompleted(r)
    }
}
