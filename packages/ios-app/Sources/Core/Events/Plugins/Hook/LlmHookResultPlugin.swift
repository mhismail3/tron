import Foundation

/// Handles `hook.llm_result` events — results from LLM-based hooks
/// (title generation, branch naming, prompt suggestions, etc.).
enum LlmHookResultPlugin: DispatchableEventPlugin {
    static let eventType = "hook.llm_result"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let hookName: String
            let hookId: String
            let hookEvent: String
            let output: String?
            let durationMs: Int?
            let model: String?
            let inputTokens: Int?
            let outputTokens: Int?
            let success: Bool
            let error: String?
        }
    }

    struct Result: EventResult {
        let hookName: String
        let hookId: String
        let output: String?
        let success: Bool
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            hookName: event.data.hookName,
            hookId: event.data.hookId,
            output: event.data.output,
            success: event.data.success
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleLlmHookResult(r)
    }
}
