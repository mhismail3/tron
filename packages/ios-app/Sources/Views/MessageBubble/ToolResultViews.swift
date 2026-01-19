import SwiftUI

// MARK: - Standalone Tool Result View (for .toolResult content type)

struct StandaloneToolResultView: View {
    let result: ToolResultData
    @State private var isExpanded = false

    /// Extract a short summary from arguments for display (e.g., command for Bash, path for Read)
    private var toolDetail: String {
        guard let args = result.arguments else { return "" }

        // Try to parse JSON and extract the most relevant field
        if let data = args.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // For Bash: show command
            if let command = json["command"] as? String {
                // Truncate long commands
                let truncated = command.count > 30 ? String(command.prefix(30)) + "..." : command
                return truncated
            }
            // For Read/Write/Edit: show file path
            if let path = json["file_path"] as? String ?? json["path"] as? String {
                // Show just filename
                return path.filename
            }
            // For Grep: show pattern
            if let pattern = json["pattern"] as? String {
                return pattern.count > 20 ? String(pattern.prefix(20)) + "..." : pattern
            }
        }
        return ""
    }

    /// Icon configuration based on tool name
    private var toolIconConfig: (name: String, color: Color) {
        guard let toolName = result.toolName?.lowercased() else {
            return (result.isError ? "xmark.circle" : "checkmark.circle", result.isError ? .tronError : .tronSuccess)
        }

        switch toolName {
        case "read":
            return ("doc.text", .tronEmerald)
        case "write":
            return ("doc.badge.plus", .tronSuccess)
        case "edit":
            return ("pencil.line", .orange)
        case "bash":
            return ("terminal", .tronEmerald)
        case "grep":
            return ("magnifyingglass", .purple)
        case "glob":
            return ("doc.text.magnifyingglass", .cyan)
        default:
            return (result.isError ? "xmark.circle" : "checkmark.circle", result.isError ? .tronError : .tronSuccess)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                let (iconName, iconColor) = toolIconConfig
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(result.isError ? .tronError : iconColor)

                // Show tool name if available, otherwise "result" or "error"
                if let toolName = result.toolName {
                    Text(toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronTextPrimary)

                    if !toolDetail.isEmpty {
                        Text(toolDetail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextMuted)
                            .lineLimit(1)
                    }
                } else {
                    Text(result.isError ? "error" : "result")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(result.isError ? .tronError : .tronTextPrimary)
                }

                Spacer()

                // Status badge
                Image(systemName: result.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(result.isError ? .tronError : .tronSuccess)

                // Duration if available
                if let durationMs = result.durationMs {
                    Text(formatDuration(durationMs))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tronSurfaceElevated)

            // Content lines
            LineNumberedContentView(
                content: result.content,
                maxCollapsedLines: 8,
                isExpanded: $isExpanded,
                fontSize: 11,
                lineNumFontSize: 10,
                maxCollapsedHeight: 160,
                lineHeight: 18
            )
        }
        .background(Color.tronSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(result.isError ? Color.tronError.opacity(0.3) : Color.tronBorder.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            let seconds = Double(ms) / 1000.0
            return String(format: "%.1fs", seconds)
        }
    }
}

// MARK: - Error Content View (Terminal-style)

struct ErrorContentView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tronError)
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(10)
        .background(Color.tronError.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.tronError.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
