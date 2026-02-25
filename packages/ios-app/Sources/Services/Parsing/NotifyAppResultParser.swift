import Foundation

/// Parses NotifyApp tool results for chip display.
enum NotifyAppResultParser {

    /// Parse NotifyApp tool to create NotifyAppChipData for chip display
    static func parseNotifyApp(from tool: ToolUseData) -> NotifyAppChipData? {
        let title = ToolArgumentParser.string("title", from: tool.arguments)
        let body = ToolArgumentParser.string("body", from: tool.arguments)

        // During tool_generating, arguments are empty — show placeholder pill
        if title == nil && body == nil {
            if tool.status == .running {
                return NotifyAppChipData(
                    toolCallId: tool.toolCallId,
                    title: "Sending notification...",
                    body: "",
                    sheetContent: nil,
                    status: .sending
                )
            }
            return nil
        }

        guard let title, let body else { return nil }

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

        // Prefer structured details from server
        if let details = tool.details,
           let sc = details["successCount"]?.value as? Int {
            successCount = sc
            failureCount = (details["failureCount"]?.value as? Int) ?? 0
        } else if let result = tool.result {
            // Fallback: regex on freetext result
            if let match = result.firstMatch(of: /to\s+(\d+)\s+device/) {
                successCount = Int(match.1)
            }
            if let match = result.firstMatch(of: /failed\s+for\s+(\d+)/) {
                failureCount = Int(match.1)
            }
        }

        if status == .failed, let result = tool.result {
            errorMessage = result
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
}
