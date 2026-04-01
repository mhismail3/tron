import SwiftUI

// MARK: - MCP Call Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for MCP Call tool results.
/// Shows the MCP server, tool name, arguments, and response.
@available(iOS 26.0, *)
struct McpCallToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronEmerald, colorScheme: colorScheme)
    }

    // MARK: - Argument Extraction

    private var server: String {
        ToolArgumentParser.string("server", from: data.arguments) ?? ""
    }

    private var tool: String {
        ToolArgumentParser.string("tool", from: data.arguments) ?? ""
    }

    private var prettyArguments: String? {
        guard let jsonData = data.arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let args = json["arguments"],
              JSONSerialization.isValidJSONObject(args) else {
            return nil
        }
        guard let argsData = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: argsData, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private var resultText: String {
        data.result ?? data.streamingOutput ?? ""
    }

    private var resultLooksLikeCode: Bool {
        let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.contains("```")
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "MCP Call",
            iconName: "server.rack",
            accent: .tronEmerald,
            copyContent: data.result ?? ""
        ) {
            contentBody
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                serverSection
                    .padding(.horizontal)
                statusRow
                    .padding(.horizontal)

                if let args = prettyArguments {
                    argumentsSection(args)
                        .padding(.horizontal)
                }

                switch data.status {
                case .success, .error:
                    if resultText.isEmpty {
                        ToolEmptyState(title: "Result", icon: "text.page.slash", message: "No response", accent: .tronEmerald, tint: tint)
                            .padding(.horizontal)
                    } else {
                        resultSection
                            .padding(.horizontal)
                    }
                case .running:
                    ToolRunningSpinner(title: "Result", accent: .tronEmerald, tint: tint, actionText: "Calling \(server).\(tool)...")
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Server Section

    private var serverSection: some View {
        ToolDetailSection(title: "Server", accent: .tronEmerald, tint: tint) {
            Text("\(server).\(tool)")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            EmptyView()
        }
    }

    // MARK: - Arguments Section

    private func argumentsSection(_ args: String) -> some View {
        ToolDetailSection(title: "Arguments", accent: .tronEmerald, tint: tint) {
            Text(args)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Result Section

    private var resultSection: some View {
        ToolDetailSection(title: "Result", accent: .tronEmerald, tint: tint, trailing: ToolCopyButton(content: resultText, accent: .tronEmerald)) {
            Text(resultText)
                .font(resultLooksLikeCode ? TronTypography.codeContent : TronTypography.mono(size: TronTypography.sizeBody))
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("MCP Call - Success") {
    McpCallToolDetailSheet(
        data: CommandToolChipData(
            id: "call_mcp1", toolName: "McpCall", normalizedName: "mcpcall", icon: "server.rack",
            iconColor: .tronEmerald, displayName: "MCP Call", summary: "github.list_repos",
            status: .success, durationMs: 320,
            arguments: "{\"server\": \"github\", \"tool\": \"list_repos\", \"arguments\": {\"owner\": \"anthropics\", \"limit\": 10}}",
            result: "[{\"name\": \"claude-code\", \"stars\": 12000}, {\"name\": \"anthropic-sdk\", \"stars\": 5000}]",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("MCP Call - Running") {
    McpCallToolDetailSheet(
        data: CommandToolChipData(
            id: "call_mcp2", toolName: "McpCall", normalizedName: "mcpcall", icon: "server.rack",
            iconColor: .tronEmerald, displayName: "MCP Call", summary: "slack.send_message",
            status: .running, durationMs: nil,
            arguments: "{\"server\": \"slack\", \"tool\": \"send_message\", \"arguments\": {\"channel\": \"#general\", \"text\": \"Hello\"}}",
            result: nil, isResultTruncated: false
        )
    )
}
#endif
