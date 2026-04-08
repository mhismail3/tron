import Foundation

// MARK: - Hook Event Handling

extension ChatViewModel: HookEventHandler {
    func handleLlmHookResult(_ result: LlmHookResultPlugin.Result) {
        guard pullUpPanelState.awaitingSuggestions else { return }
        guard result.hookId.contains("suggest-prompts"),
              result.success else { return }

        guard let suggestions = result.suggestions, !suggestions.isEmpty else { return }

        pullUpPanelState.suggestions = suggestions
        pullUpPanelState.awaitingSuggestions = false
    }
}
