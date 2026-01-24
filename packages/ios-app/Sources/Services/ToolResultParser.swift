import Foundation

/// Centralized tool result parsing service
/// Extracts data from tool arguments and results for UI display
/// Views should receive pre-parsed data and not perform any regex parsing
struct ToolResultParser {

    // MARK: - SpawnSubagent Parsing

    /// Parse SpawnSubagent tool to create SubagentToolData for chip display
    static func parseSpawnSubagent(from tool: ToolUseData) -> SubagentToolData? {
        // Extract task from arguments
        let task = extractTaskFromArguments(tool.arguments)

        // Extract session ID and other info from result
        let sessionId = extractSessionId(from: tool.result) ?? tool.toolCallId
        let resultStatus = extractSubagentStatus(from: tool.result)

        // Determine status based on tool status and result
        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = resultStatus ?? .completed
        case .error:
            status = .failed
        }

        // Extract additional info from result
        let resultSummary = extractResultSummary(from: tool.result)
        let error = tool.status == .error ? tool.result : nil

        return SubagentToolData(
            toolCallId: tool.toolCallId,
            subagentSessionId: sessionId,
            task: task,
            model: nil,
            status: status,
            currentTurn: 0,
            resultSummary: resultSummary,
            fullOutput: tool.result,
            duration: tool.durationMs,
            error: error,
            tokenUsage: nil
        )
    }

    /// Parse WaitForSubagent tool result to create SubagentToolData for chip display
    static func parseWaitForSubagent(from tool: ToolUseData) -> SubagentToolData? {
        // Extract sessionId from arguments (WaitForSubagent uses sessionId parameter)
        let sessionId = extractSessionIdFromArguments(tool.arguments)
            ?? extractSessionId(from: tool.result)
            ?? tool.toolCallId

        // Determine status based on tool status
        let status: SubagentStatus
        switch tool.status {
        case .running:
            status = .running
        case .success:
            status = .completed
        case .error:
            status = .failed
        }

        // Extract output and summary from result
        let (summary, fullOutput) = extractWaitForSubagentOutput(from: tool.result)
        let turns = extractTurns(from: tool.result)
        let duration = extractDurationMs(from: tool.result)
        let error = tool.status == .error ? tool.result : nil

        return SubagentToolData(
            toolCallId: tool.toolCallId,
            subagentSessionId: sessionId,
            task: "Sub-agent task",  // WaitForSubagent doesn't have the original task
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
        // Extract canvasId from arguments
        let canvasId = extractCanvasId(from: tool.arguments) ?? tool.toolCallId
        let title = extractTitle(from: tool.arguments)

        // Determine status based on tool status
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

    /// Parse TodoWrite tool result to create TodoWriteChipData for chip display
    static func parseTodoWrite(from tool: ToolUseData) -> TodoWriteChipData? {
        // Parse the last line of the result which has format:
        // "X completed, Y in progress, Z pending"
        guard let result = tool.result else { return nil }

        // Extract counts using regex pattern
        var completed = 0
        var inProgress = 0
        var pending = 0

        // Match pattern: "X completed, Y in progress, Z pending"
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
            totalCount: totalCount
        )
    }

    // MARK: - NotifyApp Parsing

    /// Parse NotifyApp tool to create NotifyAppChipData for chip display
    static func parseNotifyApp(from tool: ToolUseData) -> NotifyAppChipData? {
        // Extract title and body from arguments
        guard let title = extractNotifyAppTitle(from: tool.arguments),
              let body = extractNotifyAppBody(from: tool.arguments) else {
            return nil
        }

        // Extract optional sheetContent
        let sheetContent = extractNotifyAppSheetContent(from: tool.arguments)

        // Determine status based on tool status
        let status: NotifyAppStatus
        switch tool.status {
        case .running:
            status = .sending
        case .success:
            status = .sent
        case .error:
            status = .failed
        }

        // Parse result for success/failure counts
        var successCount: Int?
        var failureCount: Int?
        var errorMessage: String?

        if let result = tool.result {
            // Extract counts from result like "Notification sent successfully to 1 device."
            if let match = result.firstMatch(of: /to\s+(\d+)\s+device/) {
                successCount = Int(match.1)
            }
            // Extract failure count if present
            if let match = result.firstMatch(of: /failed\s+for\s+(\d+)/) {
                failureCount = Int(match.1)
            }
            // For errors, use the result as error message
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

    // MARK: - Private Extraction Helpers

    /// Extract "task" field from JSON arguments
    private static func extractTaskFromArguments(_ args: String) -> String {
        if let match = args.firstMatch(of: /"task"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return String(match.1)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return "Sub-agent task"
    }

    /// Extract "sessionId" field from JSON arguments
    private static func extractSessionIdFromArguments(_ args: String) -> String? {
        if let match = args.firstMatch(of: /"sessionId"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return nil
    }

    /// Extract output and summary from WaitForSubagent result
    private static func extractWaitForSubagentOutput(from result: String?) -> (summary: String?, fullOutput: String?) {
        guard let result = result else { return (nil, nil) }

        // Look for **Output**: section
        if let match = result.firstMatch(of: /\*\*Output\*\*:\s*\n([\s\S]*)/) {
            let output = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            // Remove trailing markdown separators
            let cleaned = output.components(separatedBy: "\n---\n").first ?? output

            // Create summary from first meaningful line
            let lines = cleaned.components(separatedBy: "\n").filter { !$0.isEmpty }
            let summary = lines.first.map { $0.count > 100 ? String($0.prefix(100)) + "..." : $0 }

            return (summary, cleaned)
        }

        // Fallback: look for "Completed" status
        if result.lowercased().contains("completed") {
            return ("Sub-agent completed", result)
        }

        return (nil, result)
    }

    /// Extract turn count from result
    private static func extractTurns(from result: String?) -> Int {
        guard let result = result else { return 0 }
        // Look for "Turns: X" or "**Turns**: X"
        if let match = result.firstMatch(of: /\*?\*?Turns\*?\*?\s*[:\|]\s*(\d+)/) {
            return Int(match.1) ?? 0
        }
        return 0
    }

    /// Extract duration in milliseconds from result
    private static func extractDurationMs(from result: String?) -> Int? {
        guard let result = result else { return nil }
        // Look for "Duration: X.Xs" or "Xms" or "X.X seconds"
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
        // Look for sess_xxx pattern directly (most reliable)
        if let match = result.firstMatch(of: /sess_[a-zA-Z0-9_-]+/) {
            return String(match.0)
        }
        // Also try: sessionId: "..."
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
        // Look for **Output**: section in WaitForSubagent results
        if let match = result.firstMatch(of: /\*\*Output\*\*:\s*\n(.+)/) {
            let output = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
            // Take first line or first 200 chars
            let firstLine = output.components(separatedBy: "\n").first ?? output
            return firstLine.count > 200 ? String(firstLine.prefix(200)) + "..." : firstLine
        }
        // For spawned messages, just return a simple summary
        if result.lowercased().contains("spawned") {
            return "Sub-agent spawned successfully"
        }
        return nil
    }

    /// Extract "canvasId" field from JSON arguments
    private static func extractCanvasId(from args: String) -> String? {
        if let match = args.firstMatch(of: /"canvasId"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return nil
    }

    /// Extract "title" field from JSON arguments
    private static func extractTitle(from args: String) -> String? {
        if let match = args.firstMatch(of: /"title"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return String(match.1)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return nil
    }

    /// Extract "title" field from NotifyApp JSON arguments
    private static func extractNotifyAppTitle(from args: String) -> String? {
        if let match = args.firstMatch(of: /"title"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return String(match.1)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return nil
    }

    /// Extract "body" field from NotifyApp JSON arguments
    private static func extractNotifyAppBody(from args: String) -> String? {
        if let match = args.firstMatch(of: /"body"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return String(match.1)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return nil
    }

    /// Extract "sheetContent" field from NotifyApp JSON arguments
    private static func extractNotifyAppSheetContent(from args: String) -> String? {
        if let match = args.firstMatch(of: /"sheetContent"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return String(match.1)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return nil
    }
}
