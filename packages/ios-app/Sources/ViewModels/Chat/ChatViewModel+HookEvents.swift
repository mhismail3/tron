import Foundation

// MARK: - Hook Event Handling

extension ChatViewModel: HookEventHandler {
    func handleLlmHookResult(_ result: LlmHookResultPlugin.Result) {
        guard pullUpPanelState.awaitingSuggestions else { return }
        guard result.hookId.contains("suggest-prompts"),
              result.success,
              let output = result.output else { return }

        let suggestions = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count < 80 }

        pullUpPanelState.suggestions = Array(suggestions.prefix(5))
        pullUpPanelState.awaitingSuggestions = false
    }
}
