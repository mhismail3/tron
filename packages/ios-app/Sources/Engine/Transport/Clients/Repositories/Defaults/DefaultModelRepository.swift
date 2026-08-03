import Foundation

// MARK: - Default Model Repository

/// Default implementation of ModelRepository.
/// Owns the active server's observable model catalog and five-minute TTL.
@Observable
@MainActor
final class DefaultModelRepository: ModelRepository {
    private let modelClient: ModelClient
    private var cacheTime: Date?
    private let cacheTTL: TimeInterval = 300
    private var refreshTask: Task<[ModelInfo], Error>?
    private var refreshID: UUID?

    // MARK: - Observable State

    /// Cached models from the last fetch
    private(set) var cachedModels: [ModelInfo] = []

    // MARK: - Initialization

    init(modelClient: ModelClient) {
        self.modelClient = modelClient
    }

    // MARK: - ModelRepository

    func list(forceRefresh: Bool = false) async throws -> [ModelInfo] {
        if !forceRefresh,
           let cacheTime,
           Date().timeIntervalSince(cacheTime) < cacheTTL {
            return cachedModels
        }

        // INVARIANT: all concurrent catalog readers share one transport call.
        // Settings prefetch, Providers, and model pickers commonly appear in
        // the same navigation interval; issuing duplicate `model.list` reads
        // would repeat live Ollama discovery without producing newer truth.
        if let refreshTask {
            return try await refreshTask.value
        }

        let modelClient = modelClient
        let task = Task { try await modelClient.list() }
        let refreshID = UUID()
        refreshTask = task
        self.refreshID = refreshID
        do {
            let models = try await task.value
            if self.refreshID == refreshID {
                ModelNameFormatter.updateFromServer(models)
                cachedModels = models
                cacheTime = Date()
                refreshTask = nil
                self.refreshID = nil
            }
            return models
        } catch {
            if self.refreshID == refreshID {
                refreshTask = nil
                self.refreshID = nil
            }
            throw error
        }
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
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        cachedModels = []
        cacheTime = nil
    }
}
