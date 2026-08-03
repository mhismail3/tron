import Foundation

/// Extracts tool arguments from either a `ToolInvocationStartedPayload` or a content block dictionary.
///
/// Used by `InterleavedContentProcessor` to resolve tool arguments consistently.
enum ToolArgumentExtractor {

    /// Extract arguments JSON string from a tool invocation payload or content block.
    ///
    /// Priority:
    /// 1. `invocationStart.arguments` — the pre-parsed string from the `tool.invocation.started` event
    /// 2. `contentBlock["arguments"]` or `contentBlock["input"]` — serialized from the dict
    ///
    /// - Returns: JSON string, or nil if no arguments could be extracted
    static func extractArguments(
        invocationStart: ToolInvocationStartedPayload?,
        contentBlock: [String: Any]
    ) -> String? {
        if let invocationStartArgs = invocationStart?.arguments {
            return invocationStartArgs
        }

        if let inputDict = (contentBlock["arguments"] ?? contentBlock["input"]) as? [String: Any],
           let jsonData = try? JSONSerialization.data(withJSONObject: inputDict, options: [.sortedKeys]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return nil
    }
}
