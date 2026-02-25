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

    // MARK: - RenderAppUI

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
