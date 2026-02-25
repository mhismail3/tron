import Foundation

/// Parses QueryAgent and WaitForAgents tool results for chip display.
enum AgentQueryResultParser {

    /// Parse QueryAgent tool to create QueryAgentChipData for chip display
    static func parseQueryAgent(from tool: ToolUseData) -> QueryAgentChipData? {
        let sessionId = ToolArgumentParser.string("sessionId", from: tool.arguments) ?? "unknown"

        let queryType: QueryType
        if let qt = ToolArgumentParser.string("queryType", from: tool.arguments) {
            queryType = QueryType(rawValue: qt) ?? .unknown
        } else {
            queryType = .unknown
        }

        let status: QueryAgentStatus
        switch tool.status {
        case .running:
            status = .querying
        case .success:
            status = .success
        case .error:
            status = .error
        }

        let resultPreview: String?
        if let result = tool.result {
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
            resultPreview = lines.first.map { $0.count > 80 ? String($0.prefix(80)) + "..." : $0 }
        } else {
            resultPreview = nil
        }

        return QueryAgentChipData(
            toolCallId: tool.toolCallId,
            sessionId: sessionId,
            queryType: queryType,
            status: status,
            durationMs: tool.durationMs,
            resultPreview: resultPreview,
            fullResult: tool.result,
            errorMessage: tool.status == .error ? tool.result : nil
        )
    }

    /// Parse WaitForAgents tool to create WaitForAgentsChipData for chip display
    static func parseWaitForAgents(from tool: ToolUseData) -> WaitForAgentsChipData? {
        let sessionIds = ToolArgumentParser.stringArray("sessionIds", from: tool.arguments) ?? []

        let mode: WaitMode
        if let m = ToolArgumentParser.string("mode", from: tool.arguments) {
            mode = WaitMode(rawValue: m) ?? .all
        } else {
            mode = .all
        }

        let status: WaitForAgentsStatus
        // Prefer structured details for timeout detection
        let timedOut: Bool
        if let details = tool.details, let to = details["timedOut"]?.value as? Bool {
            timedOut = to
        } else if let result = tool.result {
            timedOut = result.lowercased().contains("timeout")
        } else {
            timedOut = false
        }

        switch tool.status {
        case .running:
            status = .waiting
        case .success:
            status = timedOut ? .timedOut : .completed
        case .error:
            status = timedOut ? .timedOut : .error
        }

        // Count completed agents - prefer structured details
        var completedCount = 0
        if let details = tool.details,
           let results = details["results"]?.value as? [[String: Any]] {
            completedCount = results.count
        } else if let result = tool.result {
            // Fallback: regex on freetext result
            let matches = result.matches(of: /Session:\s*`sess_/)
            completedCount = matches.count
        }

        let resultPreview: String?
        if let result = tool.result {
            let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
            resultPreview = lines.first.map { $0.count > 80 ? String($0.prefix(80)) + "..." : $0 }
        } else {
            resultPreview = nil
        }

        return WaitForAgentsChipData(
            toolCallId: tool.toolCallId,
            sessionIds: sessionIds,
            mode: mode,
            status: status,
            completedCount: completedCount,
            durationMs: tool.durationMs,
            resultPreview: resultPreview,
            fullResult: tool.result,
            errorMessage: tool.status == .error ? tool.result : nil
        )
    }
}
