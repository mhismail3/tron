import Foundation

/// Owns optimistic model-switch presentation and delegates model truth to the repository.
@Observable
@MainActor
final class ModelPickerState {
    // MARK: - Published State

    /// Optimistic model name during switch (for instant UI feedback)
    private(set) var optimisticModelName: String?

    // MARK: - Dependencies

    private let modelRepository: any ModelRepository

    // MARK: - Initialization

    init(modelRepository: any ModelRepository) {
        self.modelRepository = modelRepository
    }

    // MARK: - Display Helpers

    /// Display name: optimistic if pending, else actual current model
    func displayModelName(current: String) -> String {
        optimisticModelName ?? current
    }

    /// Find model info by current model name (uses optimistic if set)
    func currentModelInfo(current: String) -> ModelInfo? {
        let displayName = displayModelName(current: current)
        return modelRepository.cachedModels.first { $0.id == displayName }
    }

    // MARK: - Model Operations

    /// Prefetch available models from server
    /// - Parameter onContextUpdate: Callback with fetched models for context window updates
    func prefetchModels(onContextUpdate: @escaping ([ModelInfo]) -> Void) async {
        guard let models = try? await modelRepository.list(forceRefresh: false) else {
            return
        }
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
            let result = try await modelRepository.switchModel(
                sessionId: sessionId,
                to: model.id,
                idempotencyKey: .userAction("model.switch")
            )
            // Clear optimistic update - real value now reflected
            optimisticModelName = nil
            onSuccess(previousModel, result.newModel)
            await onContextRefresh()
        } catch {
            // Revert optimistic update on failure
            optimisticModelName = nil
            let revertModel = modelRepository.cachedModels.first { $0.id == previousModel }
            onError(error.localizedDescription, revertModel)
        }
    }
}
