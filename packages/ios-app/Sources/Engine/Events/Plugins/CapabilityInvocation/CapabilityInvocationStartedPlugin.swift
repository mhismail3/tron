import Foundation

/// Plugin for handling capability invocation start events.
/// These events signal the beginning of a capability invocation.
enum CapabilityInvocationStartedPlugin: DispatchableEventPlugin {
    static let eventType = "capability.invocation.started"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let modelPrimitiveName: String
            let invocationId: String
            let arguments: [String: AnyCodable]?
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

    // MARK: - Result

    struct Result: EventResult {
        let modelPrimitiveName: String
        let invocationId: String
        let arguments: [String: AnyCodable]?
        let identity: CapabilityIdentity
        let timestamp: Date?

        init(
            modelPrimitiveName: String,
            invocationId: String,
            arguments: [String: AnyCodable]?,
            identity: CapabilityIdentity? = nil,
            timestamp: Date? = nil
        ) {
            self.modelPrimitiveName = modelPrimitiveName
            self.invocationId = invocationId
            self.arguments = arguments
            self.identity = identity ?? CapabilityIdentity()
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
                logger.warning("Failed to format capability arguments for \(modelPrimitiveName): \(error.localizedDescription)", category: .events)
                return ""
            }
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            modelPrimitiveName: event.data.modelPrimitiveName,
            invocationId: event.data.invocationId,
            arguments: event.data.arguments,
            identity: event.data.identity,
            timestamp: event.timestamp.flatMap(DateParser.parse)
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleCapabilityInvocationStarted(r)
    }
}
