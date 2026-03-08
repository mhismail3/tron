import Foundation

/// Routes incoming device requests to local service handlers and sends results
/// back to the server via `device.respond` RPC.
///
/// The dispatcher is created once and injected into the ChatViewModel. When a
/// `device.request` event arrives, the dispatcher:
/// 1. Identifies the target service from the method prefix (e.g., `calendar.list`)
/// 2. Calls the appropriate local handler
/// 3. Sends the result back via `device.respond` RPC
@MainActor
final class DeviceRequestDispatcher {
    private unowned let rpcClient: RPCClient

    /// Tracks handled request IDs to prevent duplicate dispatch.
    /// device.request events are global (nil sessionId) and delivered to ALL
    /// session subscribers, so multiple ChatViewModels receive the same event.
    /// Static because each ChatViewModel creates its own dispatcher instance.
    private static var handledRequestIds = Set<String>()

    init(rpcClient: RPCClient) {
        self.rpcClient = rpcClient
    }

    /// Handle an incoming device request by routing to the appropriate service.
    func handleRequest(_ result: DeviceRequestPlugin.Result) {
        guard Self.handledRequestIds.insert(result.requestId).inserted else {
            logger.debug("Device request dedup: requestId=\(result.requestId)", category: .general)
            return
        }

        let requestId = result.requestId
        let method = result.method

        Task {
            do {
                logger.info("Device request dispatching: method=\(method), requestId=\(requestId)", category: .general)
                let response = try await dispatch(method: method, params: result.params)
                logger.info("Device request responding: method=\(method), requestId=\(requestId)", category: .general)
                try await respond(requestId: requestId, result: response)
            } catch {
                logger.error("Device request failed: method=\(method), requestId=\(requestId), error=\(error)", category: .general)
                let errorResponse: [String: AnyCodable] = [
                    "error": AnyCodable(error.localizedDescription)
                ]
                try? await respond(requestId: requestId, result: errorResponse)
            }
        }
    }

    // MARK: - Routing

    private func dispatch(method: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        // Route by method prefix
        let parts = method.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            throw DeviceRequestError.unknownMethod(method)
        }

        let domain = String(parts[0])
        let action = String(parts[1])

        switch domain {
        case "calendar":
            return try await CalendarService.shared.handle(action: action, params: params)
        case "contacts":
            return try await ContactsService.shared.handle(action: action, params: params)
        case "health":
            return try await HealthService.shared.handle(action: action, params: params)
        default:
            throw DeviceRequestError.unknownMethod(method)
        }
    }

    // MARK: - Response

    private func respond(requestId: String, result: [String: AnyCodable]) async throws {
        try await rpcClient.misc.deviceRespond(requestId: requestId, result: result)
    }
}

// MARK: - Errors

enum DeviceRequestError: LocalizedError {
    case unknownMethod(String)
    case permissionDenied(String)
    case serviceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unknownMethod(let method):
            return "Unknown device method: \(method)"
        case .permissionDenied(let reason):
            return "Permission denied: \(reason)"
        case .serviceUnavailable(let service):
            return "\(service) is not available on this device"
        }
    }
}
