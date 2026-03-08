import Foundation

/// Plugin for handling device request events from the server.
///
/// The server broadcasts `device.request` events when an agent tool needs data
/// from the iOS device (calendar, contacts, health, etc.). This plugin parses
/// the request and dispatches to `DeviceRequestDispatcher` which routes to the
/// appropriate local service and sends the result back via `device.respond` RPC.
enum DeviceRequestPlugin: DispatchableEventPlugin {
    static let eventType = "device.request"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let timestamp: String?
        let data: DataPayload?

        /// Device request events are global — no session scope.
        var sessionId: String? { nil }

        struct DataPayload: Decodable, Sendable {
            let requestId: String
            let method: String
            let params: AnyCodable?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let requestId: String
        let method: String
        let params: [String: AnyCodable]?
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        nil
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else { return nil }
        let params: [String: AnyCodable]?
        if let codable = data.params, let dict = codable.dictionaryValue {
            params = dict.mapValues { AnyCodable($0) }
        } else {
            params = nil
        }
        return Result(
            requestId: data.requestId,
            method: data.method,
            params: params
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleDeviceRequest(result)
    }
}
