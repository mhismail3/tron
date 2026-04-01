import Foundation

/// Parses QueryAgent tool results for chip display.
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

}
