import Foundation

/// Centralized tool result parsing coordinator.
/// Delegates to focused parsers for each tool type.
/// Views should receive pre-parsed data and not perform any regex parsing.
enum ToolResultParser {

    // MARK: - Subagent Tools

    static func parseSpawnSubagent(from tool: ToolUseData) -> SubagentToolData? {
        SubagentResultParser.parseSpawnSubagent(from: tool)
    }

    /// WaitForSubagent uses the same parser — same data shape.
    static func parseWaitForSubagent(from tool: ToolUseData) -> SubagentToolData? {
        SubagentResultParser.parseSpawnSubagent(from: tool)
    }

    // MARK: - NotifyApp

    static func parseNotifyApp(from tool: ToolUseData) -> NotifyAppChipData? {
        NotifyAppResultParser.parseNotifyApp(from: tool)
    }

}
