import SwiftUI

// MARK: - Helper Methods

@available(iOS 26.0, *)
extension ChatView {
    /// Current model name (optimistic if pending, else actual)
    var displayModelName: String {
        optimisticModelName ?? viewModel.currentModel
    }

    /// Current model info (for reasoning level support detection)
    var currentModelInfo: ModelInfo? {
        cachedModels.first { $0.id == displayModelName }
    }

    /// UserDefaults key for storing reasoning level per session
    var reasoningLevelKey: String { "tron.reasoningLevel.\(sessionId)" }

    // MARK: - State Object Bindings

    var safariURLPresented: Binding<Bool> {
        Binding(
            get: { viewModel.browserState.safariURL != nil },
            set: { if !$0 { viewModel.browserState.safariURL = nil } }
        )
    }

    var browserWindowPresented: Binding<Bool> {
        Binding(
            get: { viewModel.browserState.showBrowserWindow },
            set: { viewModel.browserState.showBrowserWindow = $0 }
        )
    }

    var askUserQuestionPresented: Binding<Bool> {
        Binding(
            get: { viewModel.askUserQuestionState.showSheet },
            set: { viewModel.askUserQuestionState.showSheet = $0 }
        )
    }

    // MARK: - Model Operations

    /// Pre-fetch models for model picker menu
    func prefetchModels() async {
        isLoadingModels = true
        if let models = try? await rpcClient.model.list() {
            cachedModels = models
            // Update context window from server-provided model info
            viewModel.updateContextWindow(from: models)
        }
        isLoadingModels = false
    }

    /// Switch model with optimistic UI update for instant feedback
    func switchModel(to model: ModelInfo) {
        let previousModel = viewModel.currentModel

        // Optimistic update - UI updates instantly
        optimisticModelName = model.id
        // Update context window immediately with new model's value
        viewModel.contextState.currentContextWindow = model.contextWindow

        // Fire the actual switch in background
        Task {
            do {
                let result = try await rpcClient.model.switchModel(sessionId, model: model.id)
                await MainActor.run {
                    // Clear optimistic update - real value now in viewModel.currentModel
                    optimisticModelName = nil

                    // Add in-chat notification for model change
                    viewModel.addModelChangeNotification(
                        from: previousModel,
                        to: result.newModel
                    )
                    // Note: Model switch event is created by server and syncs automatically
                }
                // Refresh context from server to ensure accuracy after model switch
                // This validates context limit and current token count
                await viewModel.refreshContextFromServer()
            } catch {
                await MainActor.run {
                    // Revert optimistic update on failure
                    optimisticModelName = nil
                    // Revert context window on failure
                    if let originalModel = cachedModels.first(where: { $0.id == previousModel }) {
                        viewModel.contextState.currentContextWindow = originalModel.contextWindow
                    }
                    viewModel.showErrorAlert("Failed to switch model: \(error.localizedDescription)")
                }
            }
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
}
