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

    /// Active device request tasks, keyed by requestId.
    private var activeTasks: [String: Task<Void, Never>] = [:]

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

        let task = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.activeTasks.removeValue(forKey: requestId)
                }
            }
            do {
                logger.info("Device request dispatching: method=\(method), requestId=\(requestId)", category: .general)
                guard let self else { return }
                let response = try await self.dispatch(method: method, params: result.params)
                guard !Task.isCancelled else { return }
                logger.info("Device request responding: method=\(method), requestId=\(requestId)", category: .general)
                try await self.respond(requestId: requestId, result: response)
            } catch is CancellationError {
                logger.debug("Device request cancelled: method=\(method), requestId=\(requestId)", category: .general)
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Device request failed: method=\(method), requestId=\(requestId), error=\(error)", category: .general)
                let errorResponse: [String: AnyCodable] = [
                    "error": AnyCodable(error.localizedDescription)
                ]
                try? await self?.respond(requestId: requestId, result: errorResponse)
            }
        }
        activeTasks[requestId] = task
    }

    /// Cancel all active device request tasks (called on abort).
    func cancelAll() {
        guard !activeTasks.isEmpty else { return }
        logger.info("Cancelling \(activeTasks.count) active device request(s)", category: .general)
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
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
