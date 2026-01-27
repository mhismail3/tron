import Foundation

// MARK: - Default Model Repository

/// Default implementation of ModelRepository.
/// Wraps ModelClient and provides observable caching behavior.
@Observable
@MainActor
final class DefaultModelRepository: ModelRepository {
    private let modelClient: ModelClientProtocol

    // MARK: - Observable State

    /// Cached models from the last fetch
    private(set) var cachedModels: [ModelInfo] = []

    /// Whether models are currently being loaded
    private(set) var isLoading = false

    // MARK: - Initialization

    init(modelClient: ModelClientProtocol) {
        self.modelClient = modelClient
    }

    // MARK: - ModelRepository

    func list(forceRefresh: Bool = false) async throws -> [ModelInfo] {
        isLoading = true
        defer { isLoading = false }

        let models = try await modelClient.list(forceRefresh: forceRefresh)
        cachedModels = models
        return models
    }

    func switchModel(sessionId: String, to modelId: String) async throws -> ModelSwitchResult {
        try await modelClient.switchModel(sessionId, model: modelId)
    }

    func invalidateCache() {
        cachedModels = []
        // Also invalidate the underlying client cache if possible
        if let client = modelClient as? ModelClient {
            client.invalidateCache()
        }
    }
}
