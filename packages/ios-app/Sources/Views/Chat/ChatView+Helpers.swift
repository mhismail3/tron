import SwiftUI

// MARK: - Helper Methods

@available(iOS 26.0, *)
extension ChatView {
    /// Current model name (optimistic if pending, else actual)
    var displayModelName: String {
        viewModel.modelPickerState.displayModelName(current: viewModel.currentModel)
    }

    /// Current model info (for reasoning level support detection)
    var currentModelInfo: ModelInfo? {
        viewModel.modelPickerState.currentModelInfo(current: viewModel.currentModel)
    }

    /// Cached models from model picker state
    var cachedModels: [ModelInfo] {
        viewModel.modelPickerState.cachedModels
    }

    /// Whether models are being loaded
    var isLoadingModels: Bool {
        viewModel.modelPickerState.isLoadingModels
    }

    /// UserDefaults key for storing reasoning level per session
    var reasoningLevelKey: String { "tron.reasoningLevel.\(sessionId)" }

    // MARK: - Model Operations

    /// Pre-fetch models for model picker menu
    func prefetchModels() async {
        await viewModel.modelPickerState.prefetchModels { [weak viewModel] models in
            viewModel?.updateContextWindow(from: models)
        }
    }

    /// Switch model with optimistic UI update for instant feedback
    func switchModel(to model: ModelInfo) {
        Task {
            await viewModel.modelPickerState.switchModel(
                to: model,
                sessionId: sessionId,
                currentModel: viewModel.currentModel,
                onOptimisticSet: { [weak viewModel] _ in
                    // Update context window immediately with new model's value
                    viewModel?.contextState.currentContextWindow = model.contextWindow
                },
                onSuccess: { [weak viewModel] previousModel, newModel in
                    // Add in-chat notification for model change
                    viewModel?.addModelChangeNotification(from: previousModel, to: newModel)
                },
                onError: { [weak viewModel] errorMessage, revertModel in
                    // Revert context window on failure
                    if let revertModel {
                        viewModel?.contextState.currentContextWindow = revertModel.contextWindow
                    }
                    viewModel?.showErrorAlert("Failed to switch model: \(errorMessage)")
                },
                onContextRefresh: { [weak viewModel] in
                    // Refresh context from server to ensure accuracy after model switch
                    await viewModel?.refreshContextFromServer()
                }
            )
        }
    }

    // MARK: - Deep Link Scroll

    /// Perform scroll to deep link target with robust retry for streaming sessions
    func performDeepLinkScroll(to target: ScrollTarget) {
        // Try to find and scroll immediately
        if let messageId = viewModel.findMessageId(for: target) {
            scrollCoordinator.scrollToTarget(messageId: messageId, using: scrollProxy)
            logger.info("Deep link scroll to message: \(messageId)", category: .notification)
            scrollTarget = nil
            return
        }

        // Message not found yet - retry with increasing delays
        // This handles:
        // 1. Deep link fires before messages sync completes
        // 2. Agent is streaming and catch-up content is being processed
        // 3. Messages are being reconstructed from events
        logger.debug("Deep link target not found immediately, will retry: \(target) (messages=\(viewModel.messages.count), isProcessing=\(viewModel.isProcessing))", category: .notification)

        Task {
            // Retry up to 5 times with increasing delays: 300ms, 500ms, 800ms, 1000ms, 1500ms
            let delays: [UInt64] = [300_000_000, 500_000_000, 800_000_000, 1_000_000_000, 1_500_000_000]

            for (attempt, delay) in delays.enumerated() {
                try? await Task.sleep(nanoseconds: delay)

                // Check if target is now available
                if let messageId = viewModel.findMessageId(for: target) {
                    scrollCoordinator.scrollToTarget(messageId: messageId, using: scrollProxy)
                    logger.info("Deep link scroll to message after \(attempt + 1) retries: \(messageId)", category: .notification)
                    scrollTarget = nil
                    return
                }

                // Log progress for debugging
                logger.debug("Deep link retry \(attempt + 1)/\(delays.count): target not found (messages=\(viewModel.messages.count), isProcessing=\(viewModel.isProcessing))", category: .notification)

                // If we're still processing (streaming catch-up), keep retrying
                // If not processing and messages loaded, the target probably doesn't exist
                if !viewModel.isProcessing && viewModel.messages.count > 0 && attempt >= 2 {
                    logger.warning("Deep link target not found and not processing - may not exist: \(target)", category: .notification)
                    break
                }
            }

            logger.warning("Deep link target not found after all retries: \(target)", category: .notification)
            scrollTarget = nil
        }
    }
}
