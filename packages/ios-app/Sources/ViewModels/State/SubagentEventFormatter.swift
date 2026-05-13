import Foundation

/// Pure formatting logic for subagent event display.
enum SubagentEventFormatter {
    /// Format a capability identity for a subagent activity row.
    static func formatCapabilityTitle(_ identity: CapabilityIdentity) -> String {
        CapabilityPresentation.title(for: identity)
    }

    /// Format a capability result for display using contract metadata.
    static func formatCapabilityResult(invocation: CapabilityInvocationData) -> String {
        let trimmed = (invocation.result ?? invocation.logs.last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard invocation.status != .error else { return String(trimmed.prefix(150)) }

        let id = invocation.identity.contractId ?? invocation.identity.functionId ?? ""
        if id.hasPrefix("process::") {
            return formatProcessResult(trimmed)
        }
        if id.hasPrefix("filesystem::") {
            return formatTextResult(trimmed)
        }
        return String(trimmed.prefix(150))
    }

    static func formatCapabilityResult(identity: CapabilityIdentity, result: String, success: Bool) -> String {
        formatCapabilityResult(invocation: CapabilityInvocationData(
            id: identity.bindingDecisionId ?? identity.rootInvocationId ?? identity.stableCapabilityId,
            status: success ? .success : .error,
            result: result,
            identity: identity
        ))
    }

    /// Format process output: show first 2 lines + count if long.
    static func formatProcessResult(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count <= 3 {
            return lines.joined(separator: "\n")
        }
        let preview = lines.prefix(2).joined(separator: "\n")
        return "\(preview)\n... +\(lines.count - 2) more lines"
    }

    /// Format structured text output: show line count if long.
    static func formatTextResult(_ result: String) -> String {
        let lines = result.components(separatedBy: "\n")
        if lines.count <= 5 {
            return String(result.prefix(200))
        }
        return "\(lines.count) lines"
    }

    /// Format accumulated streaming output: show last few lines.
    static func formatAccumulatedOutput(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = cleaned.components(separatedBy: "\n")

        if lines.count <= 4 {
            return String(cleaned.prefix(300))
        }

        let lastLines = lines.suffix(3).joined(separator: "\n")
        return "...\n\(lastLines)"
    }
}
