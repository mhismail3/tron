import Foundation

/// Extracts tool arguments from either a `ToolCallPayload` or a content block dictionary.
///
/// Used by `InterleavedContentProcessor`, `AskUserQuestionTransformer`, and
/// `GetConfirmationTransformer` to resolve tool arguments consistently.
enum ToolArgumentExtractor {

    /// Extract arguments JSON string from a tool call payload or content block.
    ///
    /// Priority:
    /// 1. `toolCall.arguments` — the pre-parsed string from the `tool.call` event
    /// 2. `contentBlock["arguments"]` or `contentBlock["input"]` — serialized from the dict
    ///
    /// - Returns: JSON string, or nil if no arguments could be extracted
    static func extractArguments(
        toolCall: ToolCallPayload?,
        contentBlock: [String: Any]
    ) -> String? {
        if let toolCallArgs = toolCall?.arguments {
            return toolCallArgs
        }

        if let inputDict = (contentBlock["arguments"] ?? contentBlock["input"]) as? [String: Any],
           let jsonData = try? JSONSerialization.data(withJSONObject: inputDict, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return nil
    }
}
