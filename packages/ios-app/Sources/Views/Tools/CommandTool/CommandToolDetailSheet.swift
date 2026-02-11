import SwiftUI

// MARK: - CommandTool Detail Sheet (iOS 26)

/// Sheet view displaying command tool details
/// Shows tool icon, name, arguments, status, and result using existing result viewers
@available(iOS 26.0, *)
struct CommandToolDetailSheet: View {
    let data: CommandToolChipData
    var onOpenURL: ((URL) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isResultExpanded = true

    /// Parsed URL for openurl tools
    private var parsedURL: URL? {
        guard data.normalizedName == "openurl" else { return nil }
        let urlString = extractUrl(from: data.arguments)
        guard !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                contentView
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let url = parsedURL, let onOpenURL {
                        Button {
                            dismiss()
                            onOpenURL(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                    .font(.system(size: 14))
                                Text("Open")
                            }
                        }
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(data.iconColor)
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: data.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(data.iconColor)
                        Text(data.displayName)
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(data.iconColor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(data.iconColor)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(data.iconColor)
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Status & Duration Section
                statusSection

                // Command/Arguments Section
                argumentsSection

                // Result Section
                if let result = data.result, !result.isEmpty {
                    resultSection(result)
                } else if data.status == .running {
                    runningSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 12) {
            // Status badge
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

            // Duration
            if let duration = data.formattedDuration {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
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
                .font(.system(size: 12))
                .foregroundStyle(statusColor)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
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

    @ViewBuilder
    private var argumentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section Header
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tronTextMuted)
                Text("Arguments")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }

            // Full summary/command
            Text(fullArgumentsSummary)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tronSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Get the full arguments summary based on tool type
    private var fullArgumentsSummary: String {
        switch data.normalizedName {
        case "read", "write", "edit":
            return extractFilePath(from: data.arguments)
        case "bash":
            return extractCommand(from: data.arguments)
        case "search":
            let pattern = extractPattern(from: data.arguments)
            let path = extractPath(from: data.arguments)
            return "Pattern: \"\(pattern)\"\nPath: \(path)"
        case "glob", "find":
            return extractPattern(from: data.arguments)
        case "browsetheweb":
            return extractBrowserDetails(from: data.arguments)
        case "openurl", "webfetch":
            return extractUrl(from: data.arguments)
        case "websearch":
            return extractQuery(from: data.arguments)
        case "task":
            return extractTaskDetails(from: data.arguments)
        default:
            return data.arguments
        }
    }

    @ViewBuilder
    private func resultSection(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section Header with truncation indicator
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.tronTextMuted)
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)

                if data.isResultTruncated {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "scissors")
                            .font(.system(size: 10))
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

            // Result viewer based on tool type
            resultViewer(for: result)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.tronBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
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

    // MARK: - Result Viewer Routing

    @ViewBuilder
    private func resultViewer(for result: String) -> some View {
        switch data.normalizedName {
        case "read":
            ReadResultViewer(
                filePath: extractFilePath(from: data.arguments),
                content: result,
                isExpanded: $isResultExpanded
            )
        case "write":
            WriteResultViewer(
                filePath: extractFilePath(from: data.arguments),
                content: extractContent(from: data.arguments),
                result: result
            )
        case "edit":
            EditResultViewer(
                filePath: extractFilePath(from: data.arguments),
                result: result,
                isExpanded: $isResultExpanded
            )
        case "bash":
            BashResultViewer(
                command: extractCommand(from: data.arguments),
                output: result,
                isExpanded: $isResultExpanded
            )
        case "search":
            SearchToolViewer(
                pattern: extractPattern(from: data.arguments),
                result: result,
                isExpanded: $isResultExpanded
            )
        case "find", "glob":
            FindResultViewer(
                pattern: extractPattern(from: data.arguments),
                result: result,
                isExpanded: $isResultExpanded
            )
        case "browsetheweb":
            BrowserToolViewer(
                action: extractBrowserAction(from: data.arguments),
                result: result,
                isExpanded: $isResultExpanded
            )
        case "openurl":
            OpenURLResultViewer(
                url: extractUrl(from: data.arguments),
                result: result,
                isExpanded: $isResultExpanded
            )
        default:
            GenericResultViewer(result: result, isExpanded: $isResultExpanded)
        }
    }

    // MARK: - Argument Parsing Helpers

    /// Unescape JSON string escapes for display
    private func unescapeJSON(_ str: String) -> String {
        str.replacingOccurrences(of: "\\/", with: "/")
           .replacingOccurrences(of: "\\\"", with: "\"")
           .replacingOccurrences(of: "\\n", with: "\n")
           .replacingOccurrences(of: "\\t", with: "\t")
           .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func extractFilePath(from args: String) -> String {
        if let match = args.firstMatch(of: /"file_path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        if let match = args.firstMatch(of: /"path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private func extractPath(from args: String) -> String {
        if let match = args.firstMatch(of: /"path"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return "."
    }

    private func extractCommand(from args: String) -> String {
        if let match = args.firstMatch(of: /"command"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private func extractPattern(from args: String) -> String {
        if let match = args.firstMatch(of: /"pattern"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private func extractContent(from args: String) -> String {
        if let match = args.firstMatch(of: /"content"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private func extractBrowserAction(from args: String) -> String {
        if let match = args.firstMatch(of: /"action"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return ""
    }

    private func extractBrowserDetails(from args: String) -> String {
        let action = extractBrowserAction(from: args)
        if action == "navigate", let urlMatch = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
            return "Action: \(action)\nURL: \(unescapeJSON(String(urlMatch.1)))"
        }
        if ["click", "fill", "type", "select"].contains(action),
           let selectorMatch = args.firstMatch(of: /"selector"\s*:\s*"([^"]+)"/) {
            return "Action: \(action)\nSelector: \(unescapeJSON(String(selectorMatch.1)))"
        }
        return "Action: \(action)"
    }

    private func extractUrl(from args: String) -> String {
        if let match = args.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private func extractQuery(from args: String) -> String {
        if let match = args.firstMatch(of: /"query"\s*:\s*"([^"]+)"/) {
            return unescapeJSON(String(match.1))
        }
        return ""
    }

    private func extractTaskDetails(from args: String) -> String {
        var details = ""
        if let descMatch = args.firstMatch(of: /"description"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            details += "Description: \(unescapeJSON(String(descMatch.1)))\n"
        }
        if let promptMatch = args.firstMatch(of: /"prompt"\s*:\s*"((?:[^"\\]|\\.)*)"/) {
            details += "Prompt: \(unescapeJSON(String(promptMatch.1)))"
        }
        return details.isEmpty ? data.arguments : details
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("CommandTool Detail - Read") {
    CommandToolDetailSheet(
        data: CommandToolChipData(
            id: "call_1",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "example.swift",
            status: .success,
            durationMs: 25,
            arguments: "{\"file_path\": \"/Users/test/example.swift\"}",
            result: "import Foundation\n\nstruct Example {\n    let name: String\n    var value: Int\n}\n",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("CommandTool Detail - Bash") {
    CommandToolDetailSheet(
        data: CommandToolChipData(
            id: "call_2",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "git status --short",
            status: .success,
            durationMs: 45,
            arguments: "{\"command\": \"git status --short\"}",
            result: "M  README.md\nA  src/new-file.ts\n?? temp/",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("CommandTool Detail - Error") {
    CommandToolDetailSheet(
        data: CommandToolChipData(
            id: "call_3",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "missing.txt",
            status: .error,
            durationMs: 5,
            arguments: "{\"file_path\": \"/nonexistent/file.txt\"}",
            result: "Error: File not found at /nonexistent/file.txt",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("CommandTool Detail - Truncated") {
    CommandToolDetailSheet(
        data: CommandToolChipData(
            id: "call_4",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "large_file.swift",
            status: .success,
            durationMs: 150,
            arguments: "{\"file_path\": \"/Users/test/large_file.swift\"}",
            result: "// Large file content...\nimport Foundation\n\n// ... truncated ...\n\n... [Output truncated for performance]",
            isResultTruncated: true
        )
    )
}
#endif
