import SwiftUI

// MARK: - Search Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for Search/Grep tool results.
/// Groups results by file with language-colored file headers,
/// showing match lines with line numbers and content.
@available(iOS 26.0, *)
struct SearchToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedFiles: Set<String> = []

    private var tint: TintedColors {
        TintedColors(accent: .purple, colorScheme: colorScheme)
    }

    private var pattern: String {
        ToolArgumentParser.pattern(from: data.arguments)
    }

    private var searchPath: String {
        ToolArgumentParser.path(from: data.arguments)
    }

    private var fileFilter: String? {
        ToolArgumentParser.string("glob", from: data.arguments)
            ?? ToolArgumentParser.string("filePattern", from: data.arguments)
            ?? ToolArgumentParser.string("type", from: data.arguments)
    }

    private var outputMode: String? {
        ToolArgumentParser.string("output_mode", from: data.arguments)
    }

    private var parsedResults: [SearchFileGroup] {
        SearchResultParser.parse(data.result ?? data.streamingOutput ?? "")
    }

    private var totalMatchCount: Int {
        parsedResults.reduce(0) { $0 + $1.matches.count }
    }

    private var isTruncated: Bool {
        data.isResultTruncated || (data.result?.contains("[Output truncated") == true)
    }

    private var isLimitReached: Bool {
        data.result?.contains("[Showing") == true
    }

    private var isNoResults: Bool {
        data.result?.contains("No matches found") == true
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "File Search",
            iconName: "magnifyingglass",
            accent: .purple,
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
                SearchQuerySection(pattern: pattern, searchPath: searchPath, fileFilter: fileFilter, tint: tint)
                    .sheetSection()
                statusRow
                    .sheetSection()

                switch data.status {
                case .success:
                    if isNoResults {
                        noResultsSection
                            .sheetSection()
                    } else if outputMode == "files_with_matches" {
                        SearchFileListSection(result: data.result, tint: tint)
                            .sheetSection()
                    } else if !parsedResults.isEmpty {
                        SearchMatchesSection(parsedResults: parsedResults, result: data.result, tint: tint)
                            .sheetSection()
                    } else if let result = data.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        rawResultSection(result)
                            .sheetSection()
                    } else {
                        noResultsSection
                            .sheetSection()
                    }
                case .error:
                    if let result = data.result {
                        errorSection(result)
                            .sheetSection()
                    }
                case .running:
                    runningSection
                        .sheetSection()
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            if totalMatchCount > 0 {
                ToolInfoPill(icon: "text.line.first.and.arrowtriangle.forward", label: "\(totalMatchCount) matches", color: .purple)
            }
            if parsedResults.count > 1 {
                ToolInfoPill(icon: "doc.on.doc", label: "\(parsedResults.count) files", color: .purple)
            }
            if isTruncated || isLimitReached {
                ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
            }
        }
    }

    // MARK: - Raw Result Section (fallback for unrecognized formats)

    private func rawResultSection(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: result, accent: .purple)
            }

            VStack(alignment: .leading, spacing: 0) {
                let lines = result.components(separatedBy: "\n")
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .sectionFill(.purple)
        }
    }

    // MARK: - No Results Section

    private var noResultsSection: some View {
        ToolEmptyState(title: "Results", icon: "magnifyingglass", message: "No matches found", accent: .purple, tint: tint, subtitle: "Pattern: \(pattern)")
    }

    // MARK: - Error Section

    private func errorSection(_ result: String) -> some View {
        let classification = SearchErrorClassifier.classify(result)
        return ToolClassifiedErrorSection(errorMessage: result, classification: classification, colorScheme: colorScheme) {
            Text(result)
                .font(TronTypography.codeContent)
                .foregroundStyle(TintedColors(accent: .tronError, colorScheme: colorScheme).body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Running Section

    @ViewBuilder
    private var runningSection: some View {
        if let output = data.streamingOutput, !output.isEmpty {
            let streaming = SearchResultParser.parse(output)
            if !streaming.isEmpty {
                SearchStreamingMatchesSection(groups: streaming, tint: tint)
            } else {
                ToolRunningSpinner(title: "Results", accent: .purple, tint: tint, actionText: "Searching...")
            }
        } else {
            ToolRunningSpinner(title: "Results", accent: .purple, tint: tint, actionText: "Searching...")
        }
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("Search - Grouped Results") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s1",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"TODO\" in src",
            status: .success,
            durationMs: 120,
            arguments: "{\"pattern\": \"TODO\", \"path\": \"src\"}",
            result: "src/api/routes.ts:12: // TODO: Add rate limiting\nsrc/api/routes.ts:45: // TODO: Validate input\nsrc/auth/login.ts:28: // TODO: Add 2FA support\nsrc/utils/helpers.ts:89: // TODO: Optimize this function\nsrc/utils/helpers.ts:134: // TODO: Add caching",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - No Results") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s3",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"nonexistent\"",
            status: .success,
            durationMs: 30,
            arguments: "{\"pattern\": \"nonexistent_function\"}",
            result: "No matches found for pattern: nonexistent_function",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - Running") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s6",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"pattern\"",
            status: .running,
            durationMs: nil,
            arguments: "{\"pattern\": \"pattern\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Search - Error") {
    SearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_s7",
            toolName: "Search",
            normalizedName: "search",
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "File Search",
            summary: "\"[invalid\"",
            status: .error,
            durationMs: 5,
            arguments: "{\"pattern\": \"[invalid\"}",
            result: "Invalid regex pattern: [invalid - unterminated character class",
            isResultTruncated: false
        )
    )
}
#endif
