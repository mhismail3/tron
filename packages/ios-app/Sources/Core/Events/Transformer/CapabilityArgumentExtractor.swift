import Foundation

/// Extracts tool arguments from either a `CapabilityInvocationStartedPayload` or a content block dictionary.
///
/// Used by `InterleavedContentProcessor`, `AskUserQuestionTransformer`, and
/// `AskUserQuestionTransformer` to resolve tool arguments consistently.
enum CapabilityArgumentExtractor {

    /// Extract arguments JSON string from a capability invocation payload or content block.
    ///
    /// Priority:
    /// 1. `toolCall.arguments` — the pre-parsed string from the `capability.invocation.started` event
    /// 2. `contentBlock["arguments"]` or `contentBlock["input"]` — serialized from the dict
    ///
    /// - Returns: JSON string, or nil if no arguments could be extracted
    static func extractArguments(
        toolCall: CapabilityInvocationStartedPayload?,
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
