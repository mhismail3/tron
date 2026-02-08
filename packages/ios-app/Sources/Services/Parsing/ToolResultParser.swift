import Foundation

/// Centralized tool result parsing service
/// Extracts data from tool arguments and results for UI display
/// Views should receive pre-parsed data and not perform any regex parsing
struct ToolResultParser {

    // MARK: - SpawnSubagent Parsing

    /// Parse SpawnSubagent tool to create SubagentToolData for chip display
    static func parseSpawnSubagent(from tool: ToolUseData) -> SubagentToolData? {
        let task = ToolArgumentParser.string("task", from: tool.arguments)
            .map { $0.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"") }
            ?? "Sub-agent task"
        let model = ToolArgumentParser.string("model", from: tool.arguments)

        let sessionId = extractSessionId(from: tool.result) ?? tool.toolCallId
        let resultStatus = extractSubagentStatus(from: tool.result)

        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = resultStatus ?? .completed
        case .error:
            status = .failed
        }

        let resultSummary = extractResultSummary(from: tool.result)
        let turns = extractTurns(from: tool.result)
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

    // MARK: - RenderAppUI Parsing

    /// Parse RenderAppUI tool arguments to create RenderAppUIChipData for chip display
    static func parseRenderAppUI(from tool: ToolUseData) -> RenderAppUIChipData? {
        let canvasId = ToolArgumentParser.string("canvasId", from: tool.arguments) ?? tool.toolCallId
        let title = ToolArgumentParser.string("title", from: tool.arguments)

        let status: RenderAppUIStatus
        switch tool.status {
        case .running:
            status = .rendering
        case .success:
            status = .complete
        case .error:
            status = .error
        }

        return RenderAppUIChipData(
            toolCallId: tool.toolCallId,
            canvasId: canvasId,
            title: title,
            status: status,
            errorMessage: tool.status == .error ? tool.result : nil
        )
    }

    // MARK: - TodoWrite Parsing

    /// Parse TodoWrite tool to create TodoWriteChipData for chip display
    static func parseTodoWrite(from tool: ToolUseData) -> TodoWriteChipData? {
        guard let result = tool.result else {
            return TodoWriteChipData(
                toolCallId: tool.toolCallId,
                newCount: 0,
                doneCount: 0,
                totalCount: 0,
                status: .updating
            )
        }

        var completed = 0
        var inProgress = 0
        var pending = 0

        if let match = result.firstMatch(of: /(\d+)\s+completed,\s+(\d+)\s+in\s+progress,\s+(\d+)\s+pending/) {
            completed = Int(match.1) ?? 0
            inProgress = Int(match.2) ?? 0
            pending = Int(match.3) ?? 0
        }

        let totalCount = completed + inProgress + pending
        let newCount = inProgress + pending

        return TodoWriteChipData(
            toolCallId: tool.toolCallId,
            newCount: newCount,
            doneCount: completed,
            totalCount: totalCount,
            status: .updated
        )
    }

    // MARK: - NotifyApp Parsing

    /// Parse NotifyApp tool to create NotifyAppChipData for chip display
    static func parseNotifyApp(from tool: ToolUseData) -> NotifyAppChipData? {
        guard let title = ToolArgumentParser.string("title", from: tool.arguments),
              let body = ToolArgumentParser.string("body", from: tool.arguments) else {
            return nil
        }

        let sheetContent = ToolArgumentParser.string("sheetContent", from: tool.arguments)

        let status: NotifyAppStatus
        switch tool.status {
        case .running:
            status = .sending
        case .success:
            status = .sent
        case .error:
            status = .failed
        }

        var successCount: Int?
        var failureCount: Int?
        var errorMessage: String?

        if let result = tool.result {
            if let match = result.firstMatch(of: /to\s+(\d+)\s+device/) {
                successCount = Int(match.1)
            }
            if let match = result.firstMatch(of: /failed\s+for\s+(\d+)/) {
                failureCount = Int(match.1)
            }
            if status == .failed {
                errorMessage = result
            }
        }

        return NotifyAppChipData(
            toolCallId: tool.toolCallId,
            title: title,
            body: body,
            sheetContent: sheetContent,
            status: status,
            successCount: successCount,
            failureCount: failureCount,
            errorMessage: errorMessage
        )
    }

    // MARK: - Adapt Parsing

    /// Parse Adapt tool to create AdaptChipData for chip display
    static func parseAdapt(from tool: ToolUseData) -> AdaptChipData? {
        let action: AdaptAction
        if let actionStr = ToolArgumentParser.string("action", from: tool.arguments) {
            switch actionStr {
            case "deploy": action = .deploy
            case "status": action = .status
            case "rollback": action = .rollback
            default: action = .deploy
            }
        } else {
            action = .deploy
        }

        let status: AdaptStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = .success
        case .error:
            status = .failed
        }

        return AdaptChipData(
            toolCallId: tool.toolCallId,
            action: action,
            status: status,
            resultContent: tool.result,
            isError: tool.status == .error
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
