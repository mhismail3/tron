import Foundation

/// Protocol for model client operations.
/// Allows dependency injection for testing ModelPickerState.
@MainActor
protocol ModelClientProtocol {
    func list(forceRefresh: Bool) async throws -> [ModelInfo]
    func switchModel(_ sessionId: String, model: String) async throws -> ModelSwitchResult
}

/// Client for model-related RPC methods.
/// Handles model switching and listing with caching.
@MainActor
final class ModelClient: ModelClientProtocol {
    private weak var transport: RPCTransport?

    // Model list cache (5-minute TTL to reduce redundant server calls)
    private var modelCache: [ModelInfo]?
    private var modelCacheTime: Date?
    private let modelCacheTTL: TimeInterval = 300 // 5 minutes

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Model Methods

    func switchModel(_ sessionId: String, model: String) async throws -> ModelSwitchResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = ModelSwitchParams(sessionId: sessionId, model: model)
        let result: ModelSwitchResult = try await ws.send(
            method: "model.switch",
            params: params
        )

        if transport.currentSessionId == sessionId {
            transport.setCurrentModel(result.newModel)
        }

        logger.info("Switched model from \(result.previousModel) to \(result.newModel)", category: .session)
        return result
    }

    /// List available models with client-side caching (5-minute TTL)
    /// - Parameter forceRefresh: Bypass cache and fetch fresh data
    func list(forceRefresh: Bool = false) async throws -> [ModelInfo] {
        // Return cached models if still valid
        if !forceRefresh,
           let cached = modelCache,
           let cacheTime = modelCacheTime,
           Date().timeIntervalSince(cacheTime) < modelCacheTTL {
            return cached
        }

        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let result: ModelListResult = try await ws.send(
            method: "model.list",
            params: EmptyParams()
        )

        // Update cache and name formatter
        modelCache = result.models
        modelCacheTime = Date()
        ModelNameFormatter.updateFromServer(result.models)

        return result.models
    }

    /// Invalidate the model cache (e.g., after API key changes)
    func invalidateCache() {
        modelCache = nil
        modelCacheTime = nil
    }
}
