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
