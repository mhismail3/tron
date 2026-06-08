import Foundation

/// Plugin for handling canonical capability invocation completion events.
/// The stream and event-store payload both use `content` + `isError`; success
/// is derived in the view model layer so live and reconstructed sessions cannot
/// drift into parallel schemas.
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
            let content: String
            let isError: Bool
            let duration: Int
            let details: CapabilityResultDetails?
            /// Raw details dictionary for capability-specific structured results
            let rawDetails: [String: AnyCodable]?
            let identity: CapabilityIdentity

            enum CodingKeys: String, CodingKey {
                case invocationId, modelPrimitiveName, content, isError, duration, details
                case operationName, operation, traceId, rootInvocationId, themeColor, presentationHints
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                invocationId = try container.decode(String.self, forKey: .invocationId)
                modelPrimitiveName = try container.decodeIfPresent(String.self, forKey: .modelPrimitiveName)
                content = try container.decode(String.self, forKey: .content)
                isError = try container.decode(Bool.self, forKey: .isError)
                duration = try container.decode(Int.self, forKey: .duration)
                details = try container.decodeIfPresent(CapabilityResultDetails.self, forKey: .details)
                rawDetails = try container.decodeIfPresent([String: AnyCodable].self, forKey: .details)
                identity = CapabilityIdentity(
                    modelPrimitiveName: try container.decodeIfPresent(String.self, forKey: .modelPrimitiveName),
                    operationName: try container.decodeIfPresent(String.self, forKey: .operationName)
                        ?? container.decodeIfPresent(String.self, forKey: .operation),
                    traceId: try container.decodeIfPresent(String.self, forKey: .traceId),
                    rootInvocationId: try container.decodeIfPresent(String.self, forKey: .rootInvocationId),
                    themeColor: try container.decodeIfPresent(String.self, forKey: .themeColor),
                    presentationHints: try container.decodeIfPresent([String: AnyCodable].self, forKey: .presentationHints)
                )
            }
        }

        /// Details structure for capability results (e.g., screenshot data).
        struct CapabilityResultDetails: Decodable, Sendable {
            let screenshot: String?
            let format: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let invocationId: String
        let modelPrimitiveName: String?
        let success: Bool
        let content: String
        let duration: Int?
        let details: EventData.CapabilityResultDetails?
        /// Raw details dictionary for capability-specific structured results
        let rawDetails: [String: AnyCodable]?
        let identity: CapabilityIdentity
        let timestamp: Date?

        init(
            invocationId: String,
            modelPrimitiveName: String?,
            isError: Bool,
            content: String,
            duration: Int?,
            details: EventData.CapabilityResultDetails?,
            rawDetails: [String: AnyCodable]?,
            identity: CapabilityIdentity? = nil,
            timestamp: Date? = nil
        ) {
            self.invocationId = invocationId
            self.modelPrimitiveName = modelPrimitiveName
            self.success = !isError
            self.content = content
            self.duration = duration
            self.details = details
            self.rawDetails = rawDetails
            self.identity = identity ?? CapabilityIdentity()
            self.timestamp = timestamp
        }

        /// Display-friendly result text.
        var displayResult: String {
            content
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            invocationId: event.data.invocationId,
            modelPrimitiveName: event.data.modelPrimitiveName,
            isError: event.data.isError,
            content: event.data.content,
            duration: event.data.duration,
            details: event.data.details,
            rawDetails: event.data.rawDetails,
            identity: event.data.identity,
            timestamp: event.timestamp.flatMap(DateParser.parse)
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCapabilityInvocationCompleted(r)
    }
}
