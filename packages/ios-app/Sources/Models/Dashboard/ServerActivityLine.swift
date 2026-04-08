import Foundation

/// Lightweight server-side activity summary line.
/// Enriched client-side with ToolRegistry for icons, colors, display names, and argument summaries.
struct ServerActivityLine: Decodable, Hashable, Sendable {
    let kind: String
    let text: String?
    let toolName: String?
    let toolArgs: AnyCodable?
    let durationMs: Int?
    let isError: Bool?
    let turns: Int?

    func toActivityLine() -> ActivityLine {
        switch kind {
        case "userPrompt":
            return ActivityLine(kind: .userPrompt, text: text ?? "")
        case "text":
            return ActivityLine(kind: .text, text: text ?? "")
        case "thinking":
            return ActivityLine(kind: .thinking, text: "Thinking")
        case "tool":
            let name = toolName ?? "unknown"
            let descriptor = ToolRegistry.descriptor(for: name)
            let argsJSON = serializeArgs(toolArgs)
            let summary = descriptor.summaryExtractor(argsJSON)
            let durationStr = durationMs.map { SessionStreamBuffer.formatDuration($0) }
            return ActivityLine(
                kind: .toolStart,
                text: name,
                icon: descriptor.icon,
                iconColor: ToolColor(fromDescriptorName: descriptor.iconColorName),
                toolName: name,
                displayName: descriptor.displayName,
                summary: summary.isEmpty ? nil : summary,
                duration: durationStr,
                status: (isError == true) ? .error : .success
            )
        case "subagentDone":
            let t = turns ?? 0
            let durationStr = durationMs.map { SessionStreamBuffer.formatDuration($0) }
            return ActivityLine(kind: .subagentDone, text: "Agent complete (\(t) turns)", duration: durationStr)
        case "subagentFailed":
            return ActivityLine(kind: .subagentFailed, text: text ?? "Agent failed")
        default:
            return ActivityLine(kind: .text, text: text ?? "")
        }
    }

    private func serializeArgs(_ args: AnyCodable?) -> String {
        guard let args = args else { return "{}" }
        let val = args.value
        guard JSONSerialization.isValidJSONObject(val) else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: val),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
