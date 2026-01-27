import Foundation

/// State object managing model picker operations.
/// Extracts model-related state and operations from ChatView.
/// Handles prefetching, optimistic updates, and model switching.
@Observable
@MainActor
final class ModelPickerState {
    // MARK: - Published State

    /// Cached list of available models
    private(set) var cachedModels: [ModelInfo] = []

    /// Whether models are currently being loaded
    private(set) var isLoadingModels = false

    /// Optimistic model name during switch (for instant UI feedback)
    private(set) var optimisticModelName: String?

    // MARK: - Dependencies

    private let modelClient: ModelClientProtocol

    // MARK: - Initialization

    init(modelClient: ModelClientProtocol) {
        self.modelClient = modelClient
    }

    // MARK: - Display Helpers

    /// Display name: optimistic if pending, else actual current model
    func displayModelName(current: String) -> String {
        optimisticModelName ?? current
    }

    /// Find model info by current model name (uses optimistic if set)
    func currentModelInfo(current: String) -> ModelInfo? {
        let displayName = displayModelName(current: current)
        return cachedModels.first { $0.id == displayName }
    }

    // MARK: - Model Operations

    /// Prefetch available models from server
    /// - Parameter onContextUpdate: Callback with fetched models for context window updates
    func prefetchModels(onContextUpdate: @escaping ([ModelInfo]) -> Void) async {
        isLoadingModels = true
        defer { isLoadingModels = false }

        guard let models = try? await modelClient.list(forceRefresh: false) else {
            return
        }
        cachedModels = models
        onContextUpdate(models)
    }

    /// Switch model with optimistic UI update
    /// - Parameters:
    ///   - model: Target model to switch to
    ///   - sessionId: Current session ID
    ///   - currentModel: Current model name (for revert on failure)
    ///   - onOptimisticSet: Called when optimistic name is set (for context window update)
    ///   - onSuccess: Called on successful switch with previous and new model names
    ///   - onError: Called on failure with error message and model to revert to
    ///   - onContextRefresh: Called after success to refresh context from server
    func switchModel(
        to model: ModelInfo,
        sessionId: String,
        currentModel: String,
        onOptimisticSet: @escaping (String) -> Void,
        onSuccess: @escaping (String, String) -> Void,
        onError: @escaping (String, ModelInfo?) -> Void,
        onContextRefresh: @escaping () async -> Void
    ) async {
        let previousModel = currentModel

        // Optimistic update - UI updates instantly
        optimisticModelName = model.id
        onOptimisticSet(model.id)

        do {
            let result = try await modelClient.switchModel(sessionId, model: model.id)
            // Clear optimistic update - real value now reflected
            optimisticModelName = nil
            onSuccess(previousModel, result.newModel)
            await onContextRefresh()
        } catch {
            // Revert optimistic update on failure
            optimisticModelName = nil
            let revertModel = cachedModels.first { $0.id == previousModel }
            onError(error.localizedDescription, revertModel)
        }
    }

    // MARK: - Test Helpers (internal for tests)

    /// Set cached models directly (for testing)
    func setCachedModels(_ models: [ModelInfo]) {
        cachedModels = models
    }

    /// Set optimistic model name directly (for testing)
    func setOptimisticModelName(_ name: String?) {
        optimisticModelName = name
    }
}
