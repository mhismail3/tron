import Foundation

/// Plugin for handling canonical tool invocation completion events.
/// The stream and event-store payload both use `content` + `isError`; success
/// is derived in the view model layer so live and reconstructed sessions cannot
/// drift into parallel schemas.
enum ToolInvocationCompletedPlugin: DispatchableEventPlugin {
    static let eventType = "tool.invocation.completed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let invocationId: String
            let toolName: String
            let content: String
            let isError: Bool
            let duration: Int
            let details: ToolResultDetails?
            /// Raw details dictionary for tool-specific structured results
            let rawDetails: [String: AnyCodable]?
            let identity: ToolIdentity

            enum CodingKeys: String, CodingKey {
                case invocationId, toolName, content, isError, duration, details
                case traceId, rootInvocationId, themeColor, presentationHints
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                invocationId = try container.decode(String.self, forKey: .invocationId)
                toolName = try container.decode(String.self, forKey: .toolName)
                content = try container.decode(String.self, forKey: .content)
                isError = try container.decode(Bool.self, forKey: .isError)
                duration = try container.decode(Int.self, forKey: .duration)
                details = try container.decodeIfPresent(ToolResultDetails.self, forKey: .details)
                rawDetails = try container.decodeIfPresent([String: AnyCodable].self, forKey: .details)
                identity = ToolIdentity(
                    toolName: toolName,
                    traceId: try container.decodeIfPresent(String.self, forKey: .traceId),
                    rootInvocationId: try container.decodeIfPresent(String.self, forKey: .rootInvocationId),
                    themeColor: try container.decodeIfPresent(String.self, forKey: .themeColor),
                    presentationHints: try container.decodeIfPresent([String: AnyCodable].self, forKey: .presentationHints)
                )
            }
        }

        /// Details structure for tool results (e.g., screenshot data).
        struct ToolResultDetails: Decodable, Sendable {
            let screenshot: String?
            let format: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let invocationId: String
        let toolName: String
        let success: Bool
        let content: String
        let duration: Int?
        let details: EventData.ToolResultDetails?
        /// Raw details dictionary for tool-specific structured results
        let rawDetails: [String: AnyCodable]?
        let identity: ToolIdentity
        let timestamp: Date?
        let failure: CanonicalFailurePayload?

        init(
            invocationId: String,
            toolName: String,
            isError: Bool,
            content: String,
            duration: Int?,
            details: EventData.ToolResultDetails?,
            rawDetails: [String: AnyCodable]?,
            identity: ToolIdentity? = nil,
            timestamp: Date? = nil,
            failure: CanonicalFailurePayload? = nil
        ) {
            self.invocationId = invocationId
            self.toolName = toolName
            self.success = !isError
            self.content = content
            self.duration = duration
            self.details = details
            self.rawDetails = rawDetails
            self.identity = identity ?? ToolIdentity()
            self.timestamp = timestamp
            self.failure = failure
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
            toolName: event.data.toolName,
            isError: event.data.isError,
            content: event.data.content,
            duration: event.data.duration,
            details: event.data.details,
            rawDetails: event.data.rawDetails,
            identity: event.data.identity,
            timestamp: event.timestamp.flatMap(DateParser.parse),
            failure: CanonicalFailurePayload.fromDetails(event.data.rawDetails)
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleToolInvocationCompleted(r)
    }
}
