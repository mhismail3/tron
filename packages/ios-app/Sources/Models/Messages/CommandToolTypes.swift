import Foundation
import SwiftUI

// MARK: - Command Tool Status

/// Status for command tool execution
enum CommandToolStatus: Equatable {
    case running
    case success
    case error
}

// MARK: - Result Truncation

/// Constants for result truncation to prevent performance issues
enum ResultTruncation {
    /// Maximum number of lines to display in result viewers
    static let maxLines = 35

    /// Maximum number of characters to keep in result
    static let maxCharacters = 2_800

    /// Message appended when content is truncated
    static let truncationMessage = "\n\n... [Output truncated for performance]"

    /// Truncate content to fit within limits
    /// Returns (truncatedContent, wasTruncated)
    static func truncate(_ content: String) -> (String, Bool) {
        guard !content.isEmpty else { return (content, false) }

        // First check character limit (fast check)
        if content.count > maxCharacters {
            let truncated = String(content.prefix(maxCharacters)) + truncationMessage
            return (truncated, true)
        }

        // Then check line limit
        let lines = content.components(separatedBy: "\n")
        if lines.count > maxLines {
            let truncated = lines.prefix(maxLines).joined(separator: "\n") + truncationMessage
            return (truncated, true)
        }

        return (content, false)
    }
}

// MARK: - Command Tool Chip Data

/// Unified data for all command tool chips
/// Used to display command tools (Read, Write, Edit, Bash, etc.) as tappable chips
struct CommandToolChipData: Equatable, Identifiable {
    /// Tool call ID (used as unique identifier)
    let id: String
    /// Original tool name as received
    let toolName: String
    /// Normalized (lowercased) tool name for routing
    let normalizedName: String

    // Display properties
    /// SF Symbol name for the tool icon
    let icon: String
    /// Icon color
    let iconColor: Color
    /// Human-readable display name
    let displayName: String
    /// Truncated summary (path, command, pattern, etc.)
    let summary: String

    // Status properties
    /// Current execution status
    var status: CommandToolStatus
    /// Duration in milliseconds (nil while running)
    var durationMs: Int?

    // Full data for sheet
    /// Raw JSON arguments string
    let arguments: String
    /// Tool result (nil while running, truncated if too large)
    var result: String?
    /// Whether the result was truncated for performance
    var isResultTruncated: Bool

    /// Formatted duration for display
    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

// MARK: - Command Tool Registry

/// Registry for tool configurations and routing.
/// Delegates to ToolRegistry for icon/color/displayName.
enum CommandToolRegistry {

    /// All command tools that should be rendered as chips
    static let allCommandTools: Set<String> = ToolRegistry.commandToolNames

    /// Check if a tool should be rendered as a command tool chip
    static func isCommandTool(_ toolName: String) -> Bool {
        ToolRegistry.isCommandTool(toolName)
    }

    /// Get display configuration for a tool
    static func config(for toolName: String) -> (icon: String, color: Color, displayName: String) {
        let d = ToolRegistry.descriptor(for: toolName)
        return (d.icon, d.iconColor, d.displayName)
    }
}

// MARK: - Factory Initializer

extension CommandToolChipData {

    /// Create CommandToolChipData from a ToolUseData
    init(from tool: ToolUseData) {
        let descriptor = ToolRegistry.descriptor(for: tool.toolName)

        // Truncate result if too large to prevent performance issues
        let (truncatedResult, wasTruncated) = tool.result.map { ResultTruncation.truncate($0) } ?? (nil, false)

        self.id = tool.toolCallId
        self.toolName = tool.toolName
        self.normalizedName = tool.toolName.lowercased()
        self.icon = descriptor.icon
        self.iconColor = descriptor.iconColor
        self.displayName = descriptor.displayName
        self.summary = descriptor.summaryExtractor(tool.arguments)
        self.status = Self.mapStatus(tool.status)
        self.durationMs = tool.durationMs
        self.arguments = tool.arguments
        self.result = truncatedResult
        self.isResultTruncated = wasTruncated
    }

    /// Map ToolStatus to CommandToolStatus
    private static func mapStatus(_ status: ToolStatus) -> CommandToolStatus {
        switch status {
        case .running: return .running
        case .success: return .success
        case .error: return .error
        }
    }
}
