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
            // Ensure the target message is visible before scrolling
            enteredMessageIds.insert(messageId)
            scrollCoordinator.scrollToTarget(messageId: messageId, using: scrollProxy)
            logger.info("Deep link scroll to message: \(messageId)", category: .notification)
        } else {
            logger.warning("Deep link target not found: \(target)", category: .notification)
        }
        // Clear the scroll target after processing
        scrollTarget = nil
    }

    // MARK: - Message Visibility Animation

    /// Handle initial message visibility after load.
    /// For deep links: makes all messages immediately visible then scrolls.
    /// For normal loads: stagger animates the bottom N messages.
    func handleInitialMessageVisibility() async {
        let messageCount = viewModel.messages.count
        guard messageCount > 0 else { return }

        if let target = scrollTarget {
            // Deep link: make all messages visible immediately, then scroll
            await makeAllMessagesVisible()

            // Brief delay for layout to settle before scrolling
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            await MainActor.run {
                performDeepLinkScroll(to: target)
            }
        } else {
            // Normal load: stagger animate the visible batch, older messages appear instantly
            await staggerMessageEntries()

            // Scroll to bottom after animation
            await MainActor.run {
                scrollProxy?.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    /// Make all messages visible immediately (for deep link scenarios)
    private func makeAllMessagesVisible() async {
        await MainActor.run {
            enteredMessageIds = Set(viewModel.messages.map { $0.id })
        }
        logger.debug("Made all \(viewModel.messages.count) messages visible for deep link", category: .notification)
    }

    /// Stagger message entry animations for smooth loading experience.
    /// Only animates the bottom N messages; older messages appear instantly.
    private func staggerMessageEntries() async {
        let messages = viewModel.messages
        let messageCount = messages.count
        guard messageCount > 0 else { return }

        // Messages beyond the animated batch appear instantly (no animation)
        let messagesToAnimate = min(animatedBatchSize, messageCount)
        let instantMessages = messages.dropLast(messagesToAnimate)

        // Make older messages visible immediately (no animation)
        await MainActor.run {
            for message in instantMessages {
                enteredMessageIds.insert(message.id)
            }
        }

        // Stagger animate the visible batch (bottom N messages)
        let visibleBatch = messages.suffix(messagesToAnimate)

        // Small initial delay for smooth entry
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        for (index, message) in visibleBatch.enumerated() {
            // Stagger delay between messages
            if index > 0 {
                try? await Task.sleep(nanoseconds: staggerDelayNs)
            }

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    enteredMessageIds.insert(message.id)
                }
            }
        }

        logger.debug("Staggered \(messagesToAnimate) messages, \(instantMessages.count) instant", category: .session)
    }
}
