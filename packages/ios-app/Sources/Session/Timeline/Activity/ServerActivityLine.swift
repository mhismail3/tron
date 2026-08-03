import Foundation

/// Lightweight server-side activity summary line.
/// Enriched client-side with tool identity metadata.
struct ServerActivityLine: Decodable, Hashable, Sendable {
    let kind: String
    let text: String?
    let toolArgs: AnyCodable?
    let durationMs: Int?
    let isError: Bool?
    let turns: Int?
    let toolName: String?
    let traceId: String?
    let rootInvocationId: String?
    let themeColor: String?
    let presentationHints: [String: AnyCodable]?
    let summary: String?

    func toActivityLine() -> ActivityLine? {
        switch kind {
        case "userPrompt":
            return ActivityLine(kind: .userPrompt, text: text ?? "")
        case "text":
            return ActivityLine(kind: .text, text: text ?? "")
        case "thinking":
            return ActivityLine(kind: .thinking, text: "Thinking")
        case "tool":
            let identity = toolIdentity
            guard let name = identity.toolName?.nilIfEmpty else { return nil }
            let durationStr = durationMs.map { SessionStreamBuffer.formatDuration($0) }
            return ActivityLine(
                kind: .toolInvocationStarted,
                text: name,
                icon: ToolActivityPresentation.symbol(for: identity, arguments: toolArgs),
                iconColor: ToolColor.fromTool(identity),
                toolName: name,
                displayName: ToolActivityPresentation.title(for: identity, arguments: toolArgs),
                summary: ToolActivityPresentation.summary(
                    explicit: summary,
                    arguments: toolArgs,
                    identity: identity
                ),
                duration: durationStr,
                status: (isError == true) ? .error : .success,
                toolIdentity: identity
            )
        default:
            return ActivityLine(kind: .text, text: text ?? "")
        }
    }

    private var toolIdentity: ToolIdentity {
        ToolIdentity(
            toolName: toolName,
            traceId: traceId,
            rootInvocationId: rootInvocationId,
            themeColor: themeColor,
            presentationHints: presentationHints
        )
    }
}
