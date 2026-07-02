import SwiftUI

// MARK: - Helper Methods

extension ChatView {
    /// Current model info (for attachment limits and reasoning support detection)
    var currentModelInfo: ModelInfo? {
        viewModel.modelPickerState.currentModelInfo(current: viewModel.currentModel)
    }

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
                    viewModel?.appendLocalError(dedupKey: "model.switch.failed", title: "Could not switch model", message: errorMessage)
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
    func performDeepLinkScroll(to target: ScrollTarget) async {
        scrollCoordinator.beginTargetNavigation()
        var foundTarget = false
        defer { scrollCoordinator.endTargetNavigation(foundTarget: foundTarget) }

        if let messageId = await viewModel.resolveMessageIdForDeepLink(target) {
            foundTarget = true
            for delay in [75, 150, 300] {
                guard await layoutDelay(milliseconds: delay) else { return }
                scrollCoordinator.scrollToTarget(messageId: messageId, using: scrollProxy)
            }
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
    /// Uses Swift concurrency sleeps so view cancellation during rapid
    /// navigation cancels the remaining settling work instead of scheduling
    /// stale scrolls back onto the main queue.
    func handleInitialMessageVisibility() async {
        let msgCount = viewModel.messages.count
        logger.debug("[INIT] handleInitialMessageVisibility: messages=\(msgCount) scrollProxy=\(scrollProxy != nil) hasMore=\(viewModel.hasMoreMessages) bottom=\(initDistanceFromBottom)", category: .ui)

        guard msgCount > 0 else {
            logger.debug("[INIT] No messages, marking load complete", category: .ui)
            initialLoadComplete = true
            return
        }

        if !(await waitForInitialScrollProxy()) {
            logger.warning("[INIT] scrollProxy did not become ready before reveal; continuing with fallback", category: .ui)
        }

        // Deep link: skip animation, scroll to target
        if let target = scrollTarget {
            logger.debug("[INIT] Deep link target, skipping cascade", category: .ui)
            viewModel.animationCoordinator.makeAllMessagesVisible(count: msgCount)
            initialLoadComplete = true

            scrollToBottom()
            guard await layoutDelay(milliseconds: 100) else { return }
            await performDeepLinkScroll(to: target)
            return
        }

        // Scroll to bottom repeatedly until LazyVStack heights converge.
        // Each scroll materializes cells near the viewport, revealing their true
        // heights and shifting "bottom". We break early once content height
        // stabilizes and the measured viewport is actually at the bottom. Height
        // stability alone is insufficient: SwiftUI can report stable content
        // while the viewport is still parked above the latest row.
        var contentHeightStable = false
        var bottomSettled = false
        for i in 0..<ChatTranscriptRevealPolicy.initialBottomSettleAttempts {
            let heightBefore = initContentHeight
            scrollToBottom()
            guard await layoutDelay(milliseconds: ChatTranscriptRevealPolicy.initialSettleDelayMilliseconds) else { return }
            let heightAfter = initContentHeight
            contentHeightStable = heightAfter > 0 && heightAfter == heightBefore

            bottomSettled = ChatTranscriptRevealPolicy.isReadyToReveal(
                hasScrollProxy: scrollProxy != nil,
                contentHeightStable: contentHeightStable,
                distanceFromBottom: initDistanceFromBottom
            )

            logger.debug("[INIT] scroll \(i): contentH \(heightBefore)→\(heightAfter) stable=\(contentHeightStable) bottom=\(initDistanceFromBottom) settled=\(bottomSettled)", category: .ui)

            // Require at least 2 scrolls so the first scroll has time to trigger
            // cell materialization before we accept convergence.
            if bottomSettled && i >= 1 {
                logger.debug("[INIT] bottom converged at iteration \(i)", category: .ui)
                break
            }
        }

        // One final scroll after convergence to ensure we're at the true bottom
        scrollToBottom()
        guard await layoutDelay(milliseconds: 80) else { return }
        bottomSettled = ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: scrollProxy != nil,
            contentHeightStable: contentHeightStable || initContentHeight > 0,
            distanceFromBottom: initDistanceFromBottom
        )
        if !bottomSettled {
            logger.warning("[INIT] revealing after bounded bottom-settle fallback; distance=\(initDistanceFromBottom) height=\(initContentHeight)", category: .ui)
        }

        // Fade in all messages from the correct scroll position
        logger.debug("[INIT] fading in \(viewModel.messages.count) messages, setting initialLoadComplete=true bottom=\(initDistanceFromBottom)", category: .ui)
        withAnimation(.easeOut(duration: 0.3)) {
            viewModel.animationCoordinator.makeAllMessagesVisible(count: viewModel.messages.count)
            initialLoadComplete = true
        }

        logger.debug("[INIT] Session loaded with \(viewModel.messages.count) messages", category: .session)
    }

    // MARK: - Layout Delay

    private func waitForInitialScrollProxy() async -> Bool {
        for _ in 0..<ChatTranscriptRevealPolicy.initialScrollProxyWaitAttempts {
            if scrollProxy != nil {
                return true
            }
            guard await layoutDelay(milliseconds: 25) else { return false }
        }
        return scrollProxy != nil
    }

    func scrollToBottom(
        animated: Bool = false,
        animation: Animation = .easeOut(duration: 0.2)
    ) {
        guard let scrollProxy else { return }

        if animated {
            withAnimation(animation) {
                scrollProxy.scrollTo("bottom", anchor: .bottom)
            }
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollProxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    func scrollToBottomIfAllowed(
        animated: Bool = false,
        animation: Animation = .easeOut(duration: 0.2),
        reason: String
    ) {
        guard scrollCoordinator.shouldAutoScroll else {
            logger.debug("[SCROLL] suppressed bottom scroll for \(reason)", category: .ui)
            return
        }

        scrollToBottom(animated: animated, animation: animation)
    }

    private func layoutDelay(milliseconds: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
