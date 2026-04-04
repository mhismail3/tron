import Foundation

// MARK: - Hook Event Handling

extension ChatViewModel: HookEventHandler {
    func handleLlmHookResult(_ result: LlmHookResultPlugin.Result) {
        logger.info("[SUGGEST-DEBUG] live hookResult: hookId=\(result.hookId), hookName=\(result.hookName), success=\(result.success), outputLen=\(result.output?.count ?? 0)", category: .events)

        guard result.hookId.contains("suggest-prompts"),
              result.success,
              let output = result.output else { return }

        let suggestions = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count < 80 }

        pullUpPanelState.suggestions = Array(suggestions.prefix(5))
        logger.info("[SUGGEST-DEBUG] live: set \(pullUpPanelState.suggestions.count) suggestions", category: .events)
    }
}
