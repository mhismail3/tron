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

    /// Perform scroll to deep link target
    func performDeepLinkScroll(to target: ScrollTarget) {
        if let messageId = viewModel.findMessageId(for: target) {
            scrollCoordinator.scrollToTarget(messageId: messageId, using: scrollProxy)
            logger.info("Deep link scroll to message: \(messageId)", category: .notification)
        } else {
            logger.warning("Deep link target not found: \(target)", category: .notification)
        }
        // Clear the scroll target after processing
        scrollTarget = nil
    }

    // MARK: - Message Visibility Animation

    /// Handle initial message visibility on session load.
    /// Scrolls to bottom while content is hidden, then fades everything in.
    func handleInitialMessageVisibility() async {
        guard viewModel.messages.count > 0 else {
            // No messages - just mark load complete
            initialLoadComplete = true
            return
        }

        // Deep link: skip animation, scroll to target
        if let target = scrollTarget {
            // Make all messages visible instantly (use current count)
            viewModel.animationCoordinator.makeAllMessagesVisible(count: viewModel.messages.count)
            initialLoadComplete = true

            scrollProxy?.scrollTo("bottom", anchor: .bottom)
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms for layout
            performDeepLinkScroll(to: target)
            return
        }

        // Normal load: scroll to bottom while hidden, then fade in.
        // While !initialLoadComplete and cascadeProgress=0, all messages are at opacity 0.
        // Multiple scrolls let LazyVStack materialize bottom cells and settle real heights.
        // For long sessions, estimated heights can be wildly off — each scroll gets closer
        // as LazyVStack replaces estimates with measured heights for materialized cells.

        for i in 0..<4 {
            scrollProxy?.scrollTo("bottom", anchor: .bottom)
            // Exponential backoff: 16ms, 50ms, 100ms, 150ms — gives layout time to settle
            let delay: UInt64 = switch i {
            case 0: 16_000_000
            case 1: 50_000_000
            case 2: 100_000_000
            default: 150_000_000
            }
            try? await Task.sleep(nanoseconds: delay)
        }

        // Final scroll after all layout settling
        scrollProxy?.scrollTo("bottom", anchor: .bottom)

        // Fade in all messages from the correct scroll position
        withAnimation(.easeOut(duration: 0.3)) {
            viewModel.animationCoordinator.makeAllMessagesVisible(count: viewModel.messages.count)
            initialLoadComplete = true
        }

        logger.debug("Session loaded with \(viewModel.messages.count) messages", category: .session)
    }
}
