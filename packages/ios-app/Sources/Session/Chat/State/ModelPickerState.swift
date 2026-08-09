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
        return ModelInfo.matching(displayName, in: modelRepository.cachedModels)
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
    @discardableResult
    func switchModel(
        to model: ModelInfo,
        sessionId: String,
        currentModel: String,
        onOptimisticSet: @escaping (String) -> Void,
        onSuccess: @escaping (String, String) -> Void,
        onError: @escaping (String, ModelInfo?) -> Void
    ) async -> ModelSwitchResult? {
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
            onSuccess(result.previousModel, result.newModel)
            return result
        } catch {
            // Revert optimistic update on failure
            optimisticModelName = nil
            let revertModel = ModelInfo.matching(previousModel, in: modelRepository.cachedModels)
            onError(error.localizedDescription, revertModel)
            return nil
        }
    }
}

/// Serializes session configuration writes whose validity depends on the
/// preceding write (for example, selecting a model and then one of that
/// model's reasoning levels from the same sheet commit).
@MainActor
final class SessionConfigurationQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let predecessor = tail
        tail = Task { @MainActor in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }
}
