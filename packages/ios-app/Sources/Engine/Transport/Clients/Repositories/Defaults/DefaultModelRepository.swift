import Foundation

// MARK: - Default Model Repository

/// Default implementation of ModelRepository.
/// Owns the active server's observable model catalog and five-minute TTL.
@Observable
@MainActor
final class DefaultModelRepository: ModelRepository {
    private let modelClient: ModelClientProtocol
    private var cacheTime: Date?
    private let cacheTTL: TimeInterval = 300

    // MARK: - Observable State

    /// Cached models from the last fetch
    private(set) var cachedModels: [ModelInfo] = []

    // MARK: - Initialization

    init(modelClient: ModelClientProtocol) {
        self.modelClient = modelClient
    }

    // MARK: - ModelRepository

    func list(forceRefresh: Bool = false) async throws -> [ModelInfo] {
        if !forceRefresh,
           let cacheTime,
           Date().timeIntervalSince(cacheTime) < cacheTTL {
            return cachedModels
        }

        let models = try await modelClient.list()
        ModelNameFormatter.updateFromServer(models)
        cachedModels = models
        cacheTime = Date()
        return models
    }

    func switchModel(
        sessionId: String,
        to modelId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ModelSwitchResult {
        try await modelClient.switchModel(sessionId, model: modelId, idempotencyKey: idempotencyKey)
    }

    func setReasoningLevel(
        sessionId: String,
        level: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ReasoningLevelResult {
        try await modelClient.setReasoningLevel(
            sessionId,
            level: level,
            idempotencyKey: idempotencyKey
        )
    }

    func invalidateCache() {
        cachedModels = []
        cacheTime = nil
    }
}
