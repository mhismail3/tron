import SwiftUI

// MARK: - MCP Search Tool Detail Sheet

/// Detail sheet for the MCP Search tool.
/// Displays search query, optional server filter, and results from MCP server resources.
@available(iOS 26.0, *)
struct McpSearchToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronInfo, colorScheme: colorScheme)
    }

    private var query: String {
        ToolArgumentParser.string("query", from: data.arguments) ?? ""
    }

    private var server: String? {
        ToolArgumentParser.string("server", from: data.arguments)
    }

    private var resultText: String {
        data.result ?? data.streamingOutput ?? ""
    }

    private var resultLineCount: Int {
        resultText.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "MCP Search",
            iconName: "magnifyingglass.circle",
            accent: .tronInfo,
            copyContent: data.result ?? ""
        ) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    statusRow
                        .padding(.horizontal)

                    querySection
                        .padding(.horizontal)

                    contentSection
                        .padding(.horizontal)
                }
                .padding(.vertical)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            if resultLineCount > 0 && data.status == .success {
                ToolInfoPill(
                    icon: "list.bullet",
                    label: "\(resultLineCount) result\(resultLineCount == 1 ? "" : "s")",
                    color: .tronInfo
                )
            }
            if server != nil {
                ToolInfoPill(icon: "server.rack", label: server!, color: .tronSlate)
            }
        }
    }

    // MARK: - Query Section

    private var querySection: some View {
        ToolDetailSection(title: "Query", accent: .tronInfo, tint: tint) {
            Text(query)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .textSelection(.enabled)

            if let server {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(tint.subtle)
                    Text(server)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(tint.subtle)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        switch data.status {
        case .running:
            ToolRunningSpinner(
                title: "Results",
                accent: .tronInfo,
                tint: tint,
                actionText: "Searching MCP servers..."
            )
        case .success:
            if resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ToolEmptyState(
                    title: "Results",
                    icon: "magnifyingglass",
                    message: "No results found",
                    accent: .tronInfo,
                    tint: tint,
                    subtitle: "Query: \(query)"
                )
            } else {
                resultsSection
            }
        case .error:
            if let result = data.result {
                ToolClassifiedErrorSection(
                    errorMessage: result,
                    classification: ErrorClassification(
                        icon: "magnifyingglass.circle",
                        title: "Search Failed",
                        code: nil,
                        suggestion: "Check that the MCP server is running and accessible."
                    ),
                    colorScheme: colorScheme
                )
            }
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        ToolDetailSection(title: "Results", accent: .tronInfo, tint: tint, trailing: ToolCopyButton(content: resultText, accent: .tronInfo)) {
            Text(resultText)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }
}
