import SwiftUI

// MARK: - Helper Methods

extension ChatView {
    /// Current model info (for attachment limits and reasoning support detection)
    var currentModelInfo: ModelInfo? {
        viewModel.modelPickerState.currentModelInfo(current: viewModel.currentModel)
    }

    // MARK: - Model Operations

    /// Pre-fetch models for model picker menu
    func prefetchModels(guardedBy ticket: ChatViewTaskTicket? = nil) async {
        await viewModel.modelPickerState.prefetchModels { [weak viewModel] models in
            if let ticket, !taskCoordinator.isCurrent(ticket) { return }
            viewModel?.updateContextWindow(from: models)
        }
    }

    /// Switch model with optimistic UI update for instant feedback
    func switchModel(to model: ModelInfo) {
        let modelPickerState = viewModel.modelPickerState
        let currentModel = viewModel.currentModel
        let targetSessionId = sessionId
        Task { [weak viewModel] in
            await modelPickerState.switchModel(
                to: model,
                sessionId: targetSessionId,
                currentModel: currentModel,
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
                }
            )
        }
    }

    // MARK: - Deep Link Scroll

    /// Perform scroll to deep link target
    func performDeepLinkScroll(to target: ScrollTarget, guardedBy ticket: ChatViewTaskTicket? = nil) async {
        scrollCoordinator.beginTargetNavigation()
        var foundTarget = false
        defer { scrollCoordinator.endTargetNavigation(foundTarget: foundTarget) }

        if let messageId = await viewModel.resolveMessageIdForDeepLink(target) {
            guard isCurrent(ticket), !Task.isCancelled else { return }
            foundTarget = true
            for delay in [75, 150, 300] {
                guard await layoutDelay(milliseconds: delay) else { return }
                guard isCurrent(ticket), !Task.isCancelled else { return }
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

    /// Reveal device-cached history without waiting for network reconstruction
    /// or consuming a deep-link target that may require a newer server page.
    func revealCachedTranscript(guardedBy ticket: ChatViewTaskTicket? = nil) async {
        guard !viewModel.messages.isEmpty else { return }
        await settleInitialMessageVisibility(
            guardedBy: ticket,
            honorsDeepLink: false
        )
        guard isCurrent(ticket), !Task.isCancelled else { return }
        logger.debug(
            "[INIT] Revealed \(viewModel.messages.count) cached messages while authoritative reconstruction continues",
            category: .ui
        )
    }

    /// Finish shell presentation for any reconstruction attempt that began
    /// before an authoritative history cut existed. This owner is shared by
    /// initial entry and later continuity retries so a slow successful retry
    /// cannot populate visible rows without also resolving the initial
    /// viewport and any pending deep-link target.
    func settleTranscriptAfterReconstruction(
        historyWasProvisional: Bool,
        outcome: ConnectionReconstructionOutcome,
        guardedBy ticket: ChatViewTaskTicket? = nil
    ) async {
        guard historyWasProvisional else {
            if !initialLoadComplete || scrollTarget != nil {
                await handleInitialMessageVisibility(guardedBy: ticket)
            }
            return
        }

        guard outcome == .completed else {
            if !initialLoadComplete {
                await handleInitialMessageVisibility(guardedBy: ticket)
            }
            return
        }

        if presentationMode == .workerAudit
            || !initialLoadComplete
            || scrollTarget != nil {
            await handleInitialMessageVisibility(guardedBy: ticket)
            return
        }

        viewModel.animationCoordinator.makeAllMessagesVisible(
            count: viewModel.messages.count
        )
        if ChatTranscriptRevealPolicy.shouldReconcileAuthoritativeTranscript(
            historyWasProvisional: historyWasProvisional,
            reconstructionCompleted: true,
            userScrolledAway: scrollCoordinator.userScrolledAway,
            hasDeepLinkTarget: scrollTarget != nil
        ) {
            await reconcileAuthoritativeTranscriptBottom(guardedBy: ticket)
        }
    }

    /// Handle initial message visibility on session load.
    /// Measures while content is hidden, then reveals short transcripts at the
    /// top or settles overflowing transcripts at the bottom before fading in.
    ///
    /// LazyVStack only materializes cells near the visible viewport, so each
    /// `scrollTo("bottom")` can reveal cells whose true heights move the target again.
    /// We keep the transcript hidden until the bottom anchor reports consecutive
    /// target-relative samples inside the reveal tolerance.
    ///
    /// Uses Swift concurrency sleeps so view cancellation during rapid
    /// navigation cancels the remaining settling work instead of scheduling
    /// stale scrolls back onto the main queue.
    func handleInitialMessageVisibility(guardedBy ticket: ChatViewTaskTicket? = nil) async {
        await settleInitialMessageVisibility(guardedBy: ticket, honorsDeepLink: true)
    }

    private func settleInitialMessageVisibility(
        guardedBy ticket: ChatViewTaskTicket?,
        honorsDeepLink: Bool
    ) async {
        let msgCount = viewModel.messages.count
        logger.debug("[INIT] handleInitialMessageVisibility: messages=\(msgCount) scrollProxy=\(scrollProxy != nil) hasMore=\(viewModel.hasMoreMessages) bottom=\(viewportMeasurements.initialDistanceFromBottom)", category: .ui)

        guard msgCount > 0 else {
            logger.debug("[INIT] No messages, marking load complete", category: .ui)
            guard isCurrent(ticket), !Task.isCancelled else { return }
            initialLoadComplete = true
            return
        }

        if !(await waitForInitialScrollProxy()) {
            logger.warning("[INIT] scrollProxy did not become ready before reveal; continuing with bounded reveal", category: .ui)
        }
        guard isCurrent(ticket), !Task.isCancelled else { return }

        viewportMeasurements.beginTranscriptPositioning(messageCount: msgCount)
        transcriptScrollPosition.scrollTo(edge: .bottom)

        // Deep link: skip animation, scroll to target
        if honorsDeepLink, let target = scrollTarget {
            logger.debug("[INIT] Deep link target, skipping cascade", category: .ui)
            viewModel.animationCoordinator.makeAllMessagesVisible(count: msgCount)
            guard isCurrent(ticket), !Task.isCancelled else { return }
            initialLoadComplete = true

            scrollToBottom()
            guard await layoutDelay(milliseconds: 100) else { return }
            guard isCurrent(ticket), !Task.isCancelled else { return }
            await performDeepLinkScroll(to: target, guardedBy: ticket)
            return
        }

        // Worker sessions are read-only audit artifacts with no keyboard or
        // composer. Native bottom anchoring establishes the initial viewport;
        // two bounded passes account for LazyVStack materialization without
        // inheriting interactive chat's long keyboard-aware settling loop.
        if presentationMode == .workerAudit {
            scrollToBottom()
            guard await layoutDelay(milliseconds: 50) else { return }
            guard isCurrent(ticket), !Task.isCancelled else { return }
            scrollToBottom()
            guard await layoutDelay(milliseconds: 50) else { return }
            guard isCurrent(ticket), !Task.isCancelled else { return }
            viewModel.animationCoordinator.makeAllMessagesVisible(count: viewModel.messages.count)
            initialLoadComplete = true
            logger.debug(
                "[INIT] Worker audit loaded with \(viewModel.messages.count) bottom-anchored messages",
                category: .session
            )
            return
        }

        if !(await waitForInitialScrollGeometry()) {
            logger.warning("[INIT] scroll geometry did not become ready before reveal; continuing with bounded reveal", category: .ui)
        }
        guard isCurrent(ticket), !Task.isCancelled else { return }

        if ChatTranscriptRevealPolicy.shouldRevealAtTop(
            hasScrollGeometry: viewportMeasurements.hasScrollGeometry,
            hasScrollableOverflow: viewportMeasurements.hasScrollableOverflow
        ) {
            logger.debug(
                "[INIT] transcript fits viewport; revealing at top content=\(viewportMeasurements.scrollContentHeight) viewport=\(viewportMeasurements.messageViewportHeight)",
                category: .ui
            )
            revealAllMessages()
            logger.debug("[INIT] Session loaded with \(viewModel.messages.count) top-aligned messages", category: .session)
            return
        }

        // Scroll to bottom repeatedly while LazyVStack materializes its tail.
        // Two consecutive target-relative bottom samples prove the viewport stayed
        // pinned across layout passes without feeding scroll geometry back into layout.
        var consecutiveBottomSamples = 0
        var bottomSettled = false
        for i in 0..<ChatTranscriptRevealPolicy.initialBottomSettleAttempts {
            scrollToBottom()
            guard await layoutDelay(milliseconds: ChatTranscriptRevealPolicy.initialSettleDelayMilliseconds) else { return }
            guard isCurrent(ticket), !Task.isCancelled else { return }
            let distanceFromBottom = viewportMeasurements.initialDistanceFromBottom
            if ChatTranscriptRevealPolicy.isAtInitialBottom(
                distanceFromBottom: distanceFromBottom
            ) {
                consecutiveBottomSamples += 1
            } else {
                consecutiveBottomSamples = 0
            }

            bottomSettled = ChatTranscriptRevealPolicy.isReadyToReveal(
                hasScrollProxy: scrollProxy != nil,
                consecutiveBottomSamples: consecutiveBottomSamples,
                distanceFromBottom: distanceFromBottom
            )

            logger.debug("[INIT] scroll \(i): bottom=\(distanceFromBottom) stableSamples=\(consecutiveBottomSamples) settled=\(bottomSettled)", category: .ui)

            if bottomSettled {
                logger.debug("[INIT] bottom converged at iteration \(i)", category: .ui)
                break
            }
        }

        // One final scroll after convergence to ensure we're at the true bottom
        scrollToBottom()
        guard await layoutDelay(milliseconds: 80) else { return }
        guard isCurrent(ticket), !Task.isCancelled else { return }
        let finalDistanceFromBottom = viewportMeasurements.initialDistanceFromBottom
        if ChatTranscriptRevealPolicy.isAtInitialBottom(
            distanceFromBottom: finalDistanceFromBottom
        ) {
            consecutiveBottomSamples += 1
        } else {
            consecutiveBottomSamples = 0
        }
        bottomSettled = ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: scrollProxy != nil,
            consecutiveBottomSamples: consecutiveBottomSamples,
            distanceFromBottom: finalDistanceFromBottom
        )
        if !bottomSettled {
            logger.warning("[INIT] revealing after bounded bottom-settle attempts; distance=\(finalDistanceFromBottom) stableSamples=\(consecutiveBottomSamples)", category: .ui)
        }

        // Fade in all messages from the correct scroll position
        logger.debug("[INIT] fading in \(viewModel.messages.count) messages, setting initialLoadComplete=true bottom=\(viewportMeasurements.initialDistanceFromBottom)", category: .ui)
        guard isCurrent(ticket), !Task.isCancelled else { return }
        revealAllMessages()

        logger.debug("[INIT] Session loaded with \(viewModel.messages.count) messages", category: .session)
    }

    /// Reconcile a cached viewport after the authoritative projection changes
    /// LazyVStack row heights. Every pass re-checks user ownership so a gesture
    /// that begins during reconstruction is never overridden.
    func reconcileAuthoritativeTranscriptBottom(
        guardedBy ticket: ChatViewTaskTicket? = nil
    ) async {
        guard scrollTarget == nil,
              !scrollCoordinator.userScrolledAway,
              await waitForInitialScrollProxy() else { return }
        viewportMeasurements.beginTranscriptPositioning(
            messageCount: viewModel.messages.count
        )
        transcriptScrollPosition.scrollTo(edge: .bottom)
        guard await layoutDelay(milliseconds: 20) else { return }
        guard isCurrent(ticket), !Task.isCancelled else { return }
        _ = await waitForInitialScrollGeometry()
        guard isCurrent(ticket), !Task.isCancelled else { return }
        guard ChatTranscriptRevealPolicy.shouldRequestBottomPosition(
            hasScrollGeometry: viewportMeasurements.hasScrollGeometry,
            hasScrollableOverflow: viewportMeasurements.hasScrollableOverflow
        ) else { return }

        scrollToBottom()

        for _ in 0..<ChatTranscriptRevealPolicy.initialBottomSettleAttempts {
            guard !scrollCoordinator.userScrolledAway,
                  scrollCoordinator.shouldAutoScroll else { return }
            scrollToBottomIfAllowed(reason: "authoritative cached transcript reconciliation")
            guard await layoutDelay(
                milliseconds: ChatTranscriptRevealPolicy.initialSettleDelayMilliseconds
            ) else { return }
            guard isCurrent(ticket), !Task.isCancelled else { return }
            if ChatTranscriptRevealPolicy.isAtInitialBottom(
                distanceFromBottom: viewportMeasurements.currentDistanceFromBottom
            ) {
                break
            }
        }
    }

    private func revealAllMessages() {
        let mutation = {
            viewModel.animationCoordinator.makeAllMessagesVisible(
                count: viewModel.messages.count
            )
            initialLoadComplete = true
        }
        if accessibilityReduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, mutation)
        } else {
            withAnimation(.easeOut(duration: 0.3), mutation)
        }
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

    private func waitForInitialScrollGeometry() async -> Bool {
        for _ in 0..<ChatTranscriptRevealPolicy.initialScrollGeometryWaitAttempts {
            if viewportMeasurements.hasScrollGeometry {
                return true
            }
            guard await layoutDelay(milliseconds: 25) else { return false }
        }
        return viewportMeasurements.hasScrollGeometry
    }

    private func isCurrent(_ ticket: ChatViewTaskTicket?) -> Bool {
        guard let ticket else { return true }
        return taskCoordinator.isCurrent(ticket)
    }

    func scrollToBottom(
        animated: Bool = false,
        animation: Animation = .easeOut(duration: 0.2)
    ) {
        guard let scrollProxy else { return }
        scrollCoordinator.appWillPositionScroll()
        positionScrollAtBottom(
            using: scrollProxy,
            animated: animated,
            animation: animation
        )
    }

    private func positionScrollAtBottom(
        using scrollProxy: ScrollViewProxy,
        animated: Bool,
        animation: Animation
    ) {
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
        guard ChatTranscriptRevealPolicy.shouldRequestBottomPosition(
            hasScrollGeometry: viewportMeasurements.hasScrollGeometry,
            hasScrollableOverflow: viewportMeasurements.hasScrollableOverflow
        ) else {
            logger.debug("[SCROLL] suppressed bottom scroll for undersized transcript: \(reason)", category: .ui)
            return
        }
        guard let scrollProxy, scrollCoordinator.beginAutomaticBottomScroll() else {
            logger.debug("[SCROLL] suppressed bottom scroll for \(reason)", category: .ui)
            return
        }

        positionScrollAtBottom(
            using: scrollProxy,
            animated: animated,
            animation: animation
        )
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
