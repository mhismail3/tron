import Foundation

/// Parses SpawnSubagent tool results into SubagentToolData using structured `tool.details`.
enum SubagentResultParser {

    /// Parse SpawnSubagent tool to create SubagentToolData for chip display.
    /// Requires structured `details` from server — no regex fallback.
    static func parseSpawnSubagent(from tool: ToolUseData) -> SubagentToolData? {
        let task = ToolArgumentParser.string("task", from: tool.arguments)
            .map { $0.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"") }
            ?? "Sub-agent task"
        let model = ToolArgumentParser.string("model", from: tool.arguments)

        let sessionId: String
        let resultStatus: SubagentStatus?
        let resultSummary: String?
        let turns: Int

        if let details = tool.details {
            sessionId = details["sessionId"]?.value as? String ?? ""
            if let success = details["success"]?.value as? Bool {
                resultStatus = success ? .completed : .failed
            } else {
                resultStatus = nil
            }
            resultSummary = details["resultSummary"]?.value as? String
            turns = (details["totalTurns"]?.value as? Int) ?? 0
        } else {
            sessionId = ""
            resultStatus = nil
            resultSummary = nil
            turns = 0
        }

        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = resultStatus ?? .completed
        case .error:
            status = .failed
        }

        let error = tool.status == .error ? tool.result : nil

        return SubagentToolData(
            toolCallId: tool.toolCallId,
            subagentSessionId: sessionId,
            task: task,
            model: model,
            status: status,
            currentTurn: turns,
            resultSummary: resultSummary,
            fullOutput: tool.result,
            duration: tool.durationMs,
            error: error,
            tokenUsage: nil
        )
    }
}
