import SwiftUI

// MARK: - Argument Extraction Helpers

/// Argument extraction and summarization for the generic CommandTool detail sheet.
/// Delegates to `ToolArgumentParser` for standard fields (filePath, command, pattern, etc.)
/// and provides custom extractors only for domain-specific fields (tasks, automations).
@available(iOS 26.0, *)
enum CommandToolArguments {

    static func extractTaskDetails(from args: String, fallback: String) -> String {
        var details = ""
        if let desc = ToolArgumentParser.string("description", from: args) {
            details += "Description: \(desc)\n"
        }
        if let prompt = ToolArgumentParser.string("prompt", from: args) {
            details += "Prompt: \(prompt)"
        }
        return details.isEmpty ? fallback : details
    }

    static func extractAutomationDetails(from args: String, fallback: String) -> String {
        var details = ""
        if let action = ToolArgumentParser.string("action", from: args) {
            details += "Action: \(action)\n"
        }
        if let jobId = ToolArgumentParser.string("jobId", from: args) {
            details += "Job ID: \(jobId)\n"
        }
        if let name = ToolArgumentParser.string("name", from: args) {
            details += "Name: \(name)\n"
        }
        // Schedule and payload are nested objects — extract their type field
        if let data = args.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let schedule = json["schedule"] as? [String: Any],
               let schedType = schedule["type"] as? String {
                details += "Schedule: \(schedType)\n"
            }
            if let payload = json["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {
                details += "Payload: \(payloadType)\n"
            }
        }
        return details.isEmpty ? fallback : details.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the full arguments summary for a given tool.
    static func fullSummary(for normalizedName: String, arguments: String) -> String {
        switch normalizedName {
        case "read", "write", "edit":
            return ToolArgumentParser.filePath(from: arguments)
        case "bash":
            return ToolArgumentParser.command(from: arguments)
        case "search":
            let pattern = ToolArgumentParser.pattern(from: arguments)
            let path = ToolArgumentParser.path(from: arguments)
            return "Pattern: \"\(pattern)\"\nPath: \(path)"
        case "glob", "find":
            return ToolArgumentParser.pattern(from: arguments)
        case "webfetch":
            return ToolArgumentParser.url(from: arguments)
        case "websearch":
            return ToolArgumentParser.query(from: arguments)
        case "computeruse":
            return ComputerUseSummaryHelper.summary(from: arguments)
        case "manageautomations":
            return extractAutomationDetails(from: arguments, fallback: arguments)
        default:
            return arguments
        }
    }
}

// MARK: - Section Subviews

@available(iOS 26.0, *)
struct CommandToolStatusSection: View {
    let data: CommandToolChipData

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                statusIcon
                Text(statusText)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.15))
            .clipShape(Capsule())

            if let duration = data.formattedDuration {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    Text(duration)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                }
                .foregroundStyle(.tronTextMuted)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .running:
            ProgressView()
                .scaleEffect(0.6)
                .tint(statusColor)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(statusColor)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(statusColor)
        }
    }

    private var statusText: String {
        switch data.status {
        case .running: return "Running"
        case .success: return "Completed"
        case .error: return "Failed"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .running: return .tronAmber
        case .success: return .tronSuccess
        case .error: return .tronError
        }
    }
}

@available(iOS 26.0, *)
struct CommandToolArgumentsSection: View {
    let data: CommandToolChipData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(.tronTextMuted)
                Text("Arguments")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }

            Text(CommandToolArguments.fullSummary(for: data.normalizedName, arguments: data.arguments))
                .font(TronTypography.codeContent)
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tronSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

@available(iOS 26.0, *)
struct CommandToolResultSection: View {
    let data: CommandToolChipData
    let result: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(.tronTextMuted)
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)

                if data.isResultTruncated {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "scissors")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text("Truncated")
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                    }
                    .foregroundStyle(.tronAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.tronAmber.opacity(0.15))
                    .clipShape(Capsule())
                }
            }

            CommandToolResultRouter.resultViewer(for: result, data: data)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.tronBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
    }
}

@available(iOS 26.0, *)
struct CommandToolStreamingResultSection: View {
    let data: CommandToolChipData
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.5)
                    .tint(.tronAmber)
                Text("Output")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }

            CommandToolResultRouter.resultViewer(for: output, data: data)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.tronBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
    }
}

@available(iOS 26.0, *)
struct CommandToolRunningSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(.tronTextMuted)
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(.tronAmber)
                Text("Waiting for result...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tronSurface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Result Viewer Routing

@available(iOS 26.0, *)
enum CommandToolResultRouter {
    @ViewBuilder
    static func resultViewer(for result: String, data: CommandToolChipData) -> some View {
        switch data.normalizedName {
        case "read":
            ReadResultViewer(
                filePath: ToolArgumentParser.filePath(from: data.arguments),
                content: result
            )
        case "write":
            WriteResultViewer(
                filePath: ToolArgumentParser.filePath(from: data.arguments),
                content: ToolArgumentParser.content(from: data.arguments),
                result: result
            )
        case "edit":
            EditResultViewer(
                filePath: ToolArgumentParser.filePath(from: data.arguments),
                result: result,
                details: data.details
            )
        case "bash":
            BashResultViewer(
                command: ToolArgumentParser.command(from: data.arguments),
                output: result
            )
        case "search":
            SearchToolViewer(
                pattern: ToolArgumentParser.pattern(from: data.arguments),
                result: result
            )
        case "find", "glob":
            FindResultViewer(
                pattern: ToolArgumentParser.pattern(from: data.arguments),
                result: result
            )
        case "computeruse":
            ComputerUseResultViewer(
                result: result
            )
        default:
            GenericResultViewer(result: result)
        }
    }
}
