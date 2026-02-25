import Foundation

/// Parses SpawnSubagent and WaitForSubagent tool results into SubagentToolData
enum SubagentResultParser {

    // MARK: - Public Parsing

    /// Parse SpawnSubagent tool to create SubagentToolData for chip display
    static func parseSpawnSubagent(from tool: ToolUseData) -> SubagentToolData? {
        let task = ToolArgumentParser.string("task", from: tool.arguments)
            .map { $0.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"") }
            ?? "Sub-agent task"
        let model = ToolArgumentParser.string("model", from: tool.arguments)

        // Prefer structured details for sessionId and status
        let sessionId: String
        let resultStatus: SubagentStatus?
        let resultSummary: String?
        let turns: Int

        if let details = tool.details {
            sessionId = (details["sessionId"]?.value as? String) ?? extractSessionId(from: tool.result) ?? tool.toolCallId
            if let success = details["success"]?.value as? Bool {
                resultStatus = success ? .completed : .failed
            } else {
                resultStatus = extractSubagentStatus(from: tool.result)
            }
            resultSummary = (details["summary"]?.value as? String) ?? extractResultSummary(from: tool.result)
            turns = (details["totalTurns"]?.value as? Int) ?? extractTurns(from: tool.result)
        } else {
            sessionId = extractSessionId(from: tool.result) ?? tool.toolCallId
            resultStatus = extractSubagentStatus(from: tool.result)
            resultSummary = extractResultSummary(from: tool.result)
            turns = extractTurns(from: tool.result)
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

    /// Parse WaitForSubagent tool result to create SubagentToolData for chip display
    static func parseWaitForSubagent(from tool: ToolUseData) -> SubagentToolData? {
        let sessionId = ToolArgumentParser.string("sessionId", from: tool.arguments)
            ?? extractSessionId(from: tool.result)
            ?? tool.toolCallId

        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = .completed
        case .error:
            status = .failed
        }

        let (summary, fullOutput) = extractWaitForSubagentOutput(from: tool.result)
        let turns = extractTurns(from: tool.result)
        let duration = extractDurationMs(from: tool.result)
        let error = tool.status == .error ? tool.result : nil

        return SubagentToolData(
            toolCallId: tool.toolCallId,
            subagentSessionId: sessionId,
            task: "Sub-agent task",
            model: nil,
            status: status,
            currentTurn: turns,
            resultSummary: summary,
            fullOutput: fullOutput,
            duration: duration ?? tool.durationMs,
            error: error,
            tokenUsage: nil
        )
    }

    // MARK: - Private Result Extraction Helpers
    // These parse free-text result strings (not JSON arguments), so regex is appropriate.

    /// Extract output and summary from WaitForSubagent result
    private static func extractWaitForSubagentOutput(from result: String?) -> (summary: String?, fullOutput: String?) {
        guard let result = result else { return (nil, nil) }

        if let match = result.firstMatch(of: /\*\*Output\*\*:\s*\n([\s\S]*)/) {
            let output = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = output.components(separatedBy: "\n---\n").first ?? output
            let lines = cleaned.components(separatedBy: "\n").filter { !$0.isEmpty }
            let summary = lines.first.map { $0.count > 100 ? String($0.prefix(100)) + "..." : $0 }
            return (summary, cleaned)
        }

        if result.lowercased().contains("completed") {
            return ("Sub-agent completed", result)
        }

        return (nil, result)
    }

    /// Extract turn count from result
    private static func extractTurns(from result: String?) -> Int {
        guard let result = result else { return 0 }
        if let match = result.firstMatch(of: /\*?\*?Turns\*?\*?\s*[:\|]\s*(\d+)/) {
            return Int(match.1) ?? 0
        }
        return 0
    }

    /// Extract duration in milliseconds from result
    private static func extractDurationMs(from result: String?) -> Int? {
        guard let result = result else { return nil }
        if let match = result.firstMatch(of: /Duration[:\s*\|]+\s*(\d+\.?\d*)\s*(ms|s|seconds?)/) {
            let value = Double(match.1) ?? 0
            let unit = String(match.2).lowercased()
            if unit.hasPrefix("s") && !unit.hasPrefix("second") || unit.contains("second") {
                return Int(value * 1000)
            }
            return Int(value)
        }
        return nil
    }

    /// Extract session ID from result text
    private static func extractSessionId(from result: String?) -> String? {
        guard let result = result else { return nil }
        if let match = result.firstMatch(of: /sess_[a-zA-Z0-9_-]+/) {
            return String(match.0)
        }
        if let match = result.firstMatch(of: /sessionId[:\s"]+([a-zA-Z0-9_-]+)/) {
            return String(match.1)
        }
        return nil
    }

    /// Extract subagent status from result text
    private static func extractSubagentStatus(from result: String?) -> SubagentStatus? {
        guard let result = result else { return nil }
        let lower = result.lowercased()
        if lower.contains("completed") || lower.contains("successfully") {
            return .completed
        }
        if lower.contains("failed") || lower.contains("error") {
            return .failed
        }
        if lower.contains("running") || lower.contains("spawned") {
            return .running
        }
        return nil
    }

    /// Extract result summary from result text
    private static func extractResultSummary(from result: String?) -> String? {
        guard let result = result else { return nil }
        if let match = result.firstMatch(of: /\*\*Output\*\*:\s*\n(.+)/) {
            let output = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = output.components(separatedBy: "\n").first ?? output
            return firstLine.count > 200 ? String(firstLine.prefix(200)) + "..." : firstLine
        }
        if result.lowercased().contains("spawned") {
            return "Sub-agent spawned successfully"
        }
        return nil
    }
}
