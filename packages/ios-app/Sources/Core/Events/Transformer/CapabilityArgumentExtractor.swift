import Foundation

/// Extracts capability arguments from either a `CapabilityInvocationStartedPayload` or a content block dictionary.
///
/// Used by `InterleavedContentProcessor` to resolve capability arguments consistently.
enum CapabilityArgumentExtractor {

    /// Extract arguments JSON string from a capability invocation payload or content block.
    ///
    /// Priority:
    /// 1. `invocationStart.arguments` — the pre-parsed string from the `capability.invocation.started` event
    /// 2. `contentBlock["arguments"]` or `contentBlock["input"]` — serialized from the dict
    ///
    /// - Returns: JSON string, or nil if no arguments could be extracted
    static func extractArguments(
        invocationStart: CapabilityInvocationStartedPayload?,
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
