import SwiftUI

// MARK: - Argument Extraction Helpers

/// Pure extraction helpers used by CommandToolDetailSheet to parse tool arguments.
/// Grouped as static methods on an uninhabitable enum to avoid polluting the view.
@available(iOS 26.0, *)
enum CommandToolArguments {

    /// Unescape JSON string escapes for display
    static func unescapeJSON(_ str: String) -> String {
        str.replacingOccurrences(of: "\\/", with: "/")
           .replacingOccurrences(of: "\\\"", with: "\"")
           .replacingOccurrences(of: "\\n", with: "\n")
           .replacingOccurrences(of: "\\t", with: "\t")
           .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func extractFilePath(from args: String) -> String {
        if let match = args.firstMatch(of: /"file_path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        if let match = args.firstMatch(of: /"path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    static func extractPath(from args: String) -> String {
        if let match = args.firstMatch(of: /"path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return "."
    }

    static func extractCommand(from args: String) -> String {
        if let match = args.firstMatch(of: /"command"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    static func extractPattern(from args: String) -> String {
        if let match = args.firstMatch(of: /"pattern"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    static func extractContent(from args: String) -> String {
        if let match = args.firstMatch(of: /"content"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    static func extractUrl(from args: String) -> String {
        if let match = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    static func extractQuery(from args: String) -> String {
        if let match = args.firstMatch(of: /"query"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    static func extractTaskDetails(from args: String, fallback: String) -> String {
        var details = ""
        if let descMatch = args.firstMatch(of: /"description"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            details += "Description: \(unescapeJSON(String(descMatch.1)))\n"
        }
        if let promptMatch = args.firstMatch(of: /"prompt"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            details += "Prompt: \(unescapeJSON(String(promptMatch.1)))"
        }
        return details.isEmpty ? fallback : details
    }

    static func extractAutomationDetails(from args: String, fallback: String) -> String {
        var details = ""
        if let action = args.firstMatch(of: /"action"\s*:\s*"([^"]+)"/) {
            details += "Action: \(String(action.1))\n"
        }
        if let jobId = args.firstMatch(of: /"jobId"\s*:\s*"([^"]+)"/) {
            details += "Job ID: \(String(jobId.1))\n"
        }
        if let name = args.firstMatch(of: /"name"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            details += "Name: \(unescapeJSON(String(name.1)))\n"
        }
        if let schedType = args.firstMatch(of: /"schedule"\s*:\s*\{[^}]*"type"\s*:\s*"([^"]+)"/) {
            details += "Schedule: \(String(schedType.1))\n"
        }
        if let payloadType = args.firstMatch(of: /"payload"\s*:\s*\{[^}]*"type"\s*:\s*"([^"]+)"/) {
            details += "Payload: \(String(payloadType.1))\n"
        }
        return details.isEmpty ? fallback : details.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the full arguments summary for a given tool.
    static func fullSummary(for normalizedName: String, arguments: String) -> String {
        switch normalizedName {
        case "read", "write", "edit":
            return extractFilePath(from: arguments)
        case "bash":
            return extractCommand(from: arguments)
        case "search":
            let pattern = extractPattern(from: arguments)
            let path = extractPath(from: arguments)
            return "Pattern: \"\(pattern)\"\nPath: \(path)"
        case "glob", "find":
            return extractPattern(from: arguments)
        case "webfetch":
            return extractUrl(from: arguments)
        case "websearch":
            return extractQuery(from: arguments)
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
                filePath: CommandToolArguments.extractFilePath(from: data.arguments),
                content: result
            )
        case "write":
            WriteResultViewer(
                filePath: CommandToolArguments.extractFilePath(from: data.arguments),
                content: CommandToolArguments.extractContent(from: data.arguments),
                result: result
            )
        case "edit":
            EditResultViewer(
                filePath: CommandToolArguments.extractFilePath(from: data.arguments),
                result: result
            )
        case "bash":
            BashResultViewer(
                command: CommandToolArguments.extractCommand(from: data.arguments),
                output: result
            )
        case "search":
            SearchToolViewer(
                pattern: CommandToolArguments.extractPattern(from: data.arguments),
                result: result
            )
        case "find", "glob":
            FindResultViewer(
                pattern: CommandToolArguments.extractPattern(from: data.arguments),
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
