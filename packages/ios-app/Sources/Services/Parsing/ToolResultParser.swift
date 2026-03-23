import Foundation

/// Centralized tool result parsing coordinator.
/// Delegates to focused parsers for each tool type.
/// Views should receive pre-parsed data and not perform any regex parsing.
enum ToolResultParser {

    // MARK: - Subagent Tools

    static func parseSpawnSubagent(from tool: ToolUseData) -> SubagentToolData? {
        SubagentResultParser.parseSpawnSubagent(from: tool)
    }

    static func parseWaitForSubagent(from tool: ToolUseData) -> SubagentToolData? {
        SubagentResultParser.parseWaitForSubagent(from: tool)
    }

    // MARK: - RenderUI

    static func parseRenderUI(from tool: ToolUseData) -> RenderUIChipData? {
        let canvasId = ToolArgumentParser.string("canvasId", from: tool.arguments) ?? tool.toolCallId
        let url = ToolArgumentParser.string("url", from: tool.arguments) ?? ""
        let title = ToolArgumentParser.string("title", from: tool.arguments)

        let status: RenderUIStatus
        switch tool.status {
        case .running:
            status = .rendering
        case .success:
            status = .ready
        case .error:
            status = .error
        }

        return RenderUIChipData(
            toolCallId: tool.toolCallId,
            canvasId: canvasId,
            url: url,
            title: title,
            status: status,
            errorMessage: tool.status == .error ? tool.result : nil
        )
    }

    // MARK: - TaskManager

    static func parseTaskManager(from tool: ToolUseData) -> TaskManagerChipData? {
        TaskResultParser.parseTaskManager(from: tool)
    }

    static func parseListResult(from result: String, action: String) -> ListResult? {
        TaskResultParser.parseListResult(from: result, action: action)
    }

    static func parseEntityDetail(from result: String, action: String) -> EntityDetail? {
        TaskResultParser.parseEntityDetail(from: result, action: action)
    }

    // MARK: - NotifyApp

    static func parseNotifyApp(from tool: ToolUseData) -> NotifyAppChipData? {
        NotifyAppResultParser.parseNotifyApp(from: tool)
    }

    // MARK: - Agent Query

    static func parseQueryAgent(from tool: ToolUseData) -> QueryAgentChipData? {
        AgentQueryResultParser.parseQueryAgent(from: tool)
    }

    static func parseWaitForAgents(from tool: ToolUseData) -> WaitForAgentsChipData? {
        AgentQueryResultParser.parseWaitForAgents(from: tool)
    }
}
