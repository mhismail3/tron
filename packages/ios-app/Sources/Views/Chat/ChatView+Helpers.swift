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
    ///
    /// LazyVStack only materializes cells near the visible viewport, using estimated
    /// heights (~80pt) for distant cells. Real message heights average ~170pt, so each
    /// `scrollTo("bottom")` reveals new cells whose true heights push "bottom" further
    /// away. We iterate until the content height stabilizes.
    ///
    /// Uses GCD-based delays instead of `Task.sleep` because `.task` can inherit
    /// cancellation context during rapid navigation, causing `Task.sleep` to throw
    /// immediately (the `try?` swallows it → zero delay → all iterations in 0ms).
    func handleInitialMessageVisibility() async {
        let msgCount = viewModel.messages.count
        logger.debug("[INIT] handleInitialMessageVisibility: messages=\(msgCount) scrollProxy=\(scrollProxy != nil) hasMore=\(viewModel.hasMoreMessages)", category: .ui)

        guard msgCount > 0 else {
            logger.debug("[INIT] No messages, marking load complete", category: .ui)
            initialLoadComplete = true
            return
        }

        // Deep link: skip animation, scroll to target
        if let target = scrollTarget {
            logger.debug("[INIT] Deep link target, skipping cascade", category: .ui)
            viewModel.animationCoordinator.makeAllMessagesVisible(count: msgCount)
            initialLoadComplete = true

            scrollProxy?.scrollTo("bottom", anchor: .bottom)
            await layoutDelay(milliseconds: 100)
            performDeepLinkScroll(to: target)
            return
        }

        // Scroll to bottom repeatedly until LazyVStack heights converge.
        // Each scroll materializes cells near the viewport, revealing their true
        // heights and shifting "bottom". We break early once content height
        // stabilizes (typically 2-3 iterations, ~100ms).
        for i in 0..<8 {
            let heightBefore = initContentHeight
            scrollProxy?.scrollTo("bottom", anchor: .bottom)
            await layoutDelay(milliseconds: 30)
            let heightAfter = initContentHeight

            logger.debug("[INIT] scroll \(i): contentH \(heightBefore)→\(heightAfter)", category: .ui)

            // Content height stabilized — LazyVStack finished materializing cells.
            // Require at least 2 scrolls so the first scroll has time to trigger
            // cell materialization before we check for convergence.
            if heightAfter == heightBefore && i >= 1 {
                logger.debug("[INIT] converged at iteration \(i)", category: .ui)
                break
            }
        }

        // One final scroll after convergence to ensure we're at the true bottom
        scrollProxy?.scrollTo("bottom", anchor: .bottom)

        // Fade in all messages from the correct scroll position
        logger.debug("[INIT] fading in \(viewModel.messages.count) messages, setting initialLoadComplete=true", category: .ui)
        withAnimation(.easeOut(duration: 0.3)) {
            viewModel.animationCoordinator.makeAllMessagesVisible(count: viewModel.messages.count)
            initialLoadComplete = true
        }

        logger.debug("[INIT] Session loaded with \(viewModel.messages.count) messages", category: .session)
    }

    // MARK: - Layout Delay

    /// Non-cancellable delay for layout settling. Uses GCD scheduling which is
    /// independent of Swift concurrency Task cancellation. `Task.sleep` throws
    /// `CancellationError` when the parent Task is cancelled (common during rapid
    /// navigation between sessions), and `try?` silently swallows it → zero delay.
    private func layoutDelay(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}
