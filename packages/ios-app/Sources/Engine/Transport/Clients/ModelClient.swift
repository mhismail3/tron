import Foundation

/// Protocol for model client operations.
/// Allows dependency injection for testing ModelPickerState.
@MainActor
protocol ModelClientProtocol {
    func list(forceRefresh: Bool) async throws -> [ModelInfo]
    func switchModel(
        _ sessionId: String,
        model: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ModelSwitchResult
}

/// Client for model-related engine capabilities.
/// Handles model switching and listing with caching.
final class ModelClient: EngineDomainClient, ModelClientProtocol {

    // Model list cache (5-minute TTL to reduce redundant server calls)
    private var modelCache: [ModelInfo]?
    private var modelCacheTime: Date?
    private let modelCacheTTL: TimeInterval = 300 // 5 minutes

    // MARK: - Model Methods

    func switchModel(
        _ sessionId: String,
        model: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ModelSwitchResult {
        _ = try requireTransport().requireConnection()

        let params = ModelSwitchParams(sessionId: sessionId, model: model)
        let result: ModelSwitchResult = try await invokeWrite(
            "model::switch",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )

        if currentTransport?.currentSessionId == sessionId {
            currentTransport?.setCurrentModel(result.newModel)
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

        _ = try requireTransport().requireConnection()

        let result: ModelListResult = try await invokeRead(
            "model::list",
            EmptyParams()
        )

        // Update cache and name formatter
        modelCache = result.models
        modelCacheTime = Date()
        ModelNameFormatter.updateFromServer(result.models)

        return result.models
    }

    // MARK: - Reasoning Level

    func setReasoningLevel(
        _ sessionId: String,
        level: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ReasoningLevelResult {
        _ = try requireTransport().requireConnection()

        let params = ReasoningLevelParams(sessionId: sessionId, level: level)
        return try await invokeWrite(
            "config::set_reasoning_level",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    /// Invalidate the model cache (e.g., after API key changes)
    func invalidateCache() {
        modelCache = nil
        modelCacheTime = nil
    }
}
