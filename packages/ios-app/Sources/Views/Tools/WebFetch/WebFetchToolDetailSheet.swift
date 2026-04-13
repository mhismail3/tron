import SwiftUI

// MARK: - WebFetch Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for WebFetch tool results.
/// Shows the fetched URL, source metadata, the AI-generated answer,
/// and structured error states with glass-effect containers.
@available(iOS 26.0, *)
struct WebFetchToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronInfo, colorScheme: colorScheme)
    }

    private var url: String {
        ToolArgumentParser.url(from: data.arguments)
    }

    private var prompt: String {
        ToolArgumentParser.string("prompt", from: data.arguments) ?? ""
    }

    private var method: String {
        ToolArgumentParser.string("method", from: data.arguments)?.uppercased() ?? "GET"
    }

    private var domain: String {
        ToolArgumentParser.extractDomain(from: url)
    }

    private var parsed: WebFetchParsedResult {
        WebFetchParsedResult(details: data.details, arguments: data.arguments)
    }

    private var isTruncated: Bool {
        data.isResultTruncated
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Web Fetch",
            iconName: "arrow.down.doc",
            accent: .tronInfo,
        ) {
            contentBody
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                WebFetchSourceSection(url: url, domain: domain, source: parsed.source, tint: tint)
                    .sheetSection()

                if parsed.isRawMode {
                    WebFetchRawHttpInfoSection(method: method, httpStatus: parsed.httpStatus, tint: tint)
                        .sheetSection()
                } else if !prompt.isEmpty {
                    WebFetchPromptSection(prompt: prompt, tint: tint)
                        .sheetSection()
                }

                statusRow
                    .sheetSection()

                switch data.status {
                case .success:
                    if let error = parsed.error {
                        fetchErrorSection(error)
                            .sheetSection()
                    } else if !parsed.displayContent.isEmpty {
                        if parsed.isRawMode {
                            WebFetchRawResponseBodySection(answer: parsed.displayContent, tint: tint)
                                .sheetSection()
                        } else {
                            WebFetchAnswerSection(answer: parsed.displayContent, tint: tint)
                                .sheetSection()
                        }
                    } else {
                        emptyResultSection
                            .sheetSection()
                    }
                case .error:
                    if let error = parsed.error {
                        fetchErrorSection(error)
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
            if parsed.isRawMode, let status = parsed.httpStatus {
                ToolInfoPill(
                    icon: status < 400 ? "checkmark.circle" : "exclamationmark.circle",
                    label: "HTTP \(status)",
                    color: status < 300 ? .tronEmerald : status < 400 ? .tronAmber : .tronError
                )
            }
            if !parsed.isRawMode && parsed.isCached {
                ToolInfoPill(icon: "arrow.triangle.2.circlepath", label: "Cached", color: .tronEmerald)
            }
            if parsed.isRawMode {
                ToolInfoPill(icon: "network", label: method, color: .tronInfo)
            }
            if isTruncated {
                ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
            }
        }
    }

    // MARK: - Empty Result Section

    private var emptyResultSection: some View {
        ToolEmptyState(title: parsed.isRawMode ? "Response" : "Answer", icon: "doc.text", message: "No content returned", accent: .tronInfo, tint: tint)
    }

    // MARK: - Error Section

    private func fetchErrorSection(_ errorMessage: String) -> some View {
        let classification = WebFetchDetailParser.classify(details: data.details)
            ?? ErrorClassification(
                icon: "exclamationmark.triangle.fill",
                title: "Fetch Failed",
                code: nil,
                suggestion: "An error occurred while fetching the page."
            )

        return ToolClassifiedErrorSection(
            errorMessage: errorMessage,
            classification: classification,
            colorScheme: colorScheme
        ) {
            if !url.isEmpty {
                let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
                Text(url)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(errorTint.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Running Section

    @ViewBuilder
    private var runningSection: some View {
        // During streaming, we have neither a structured details payload nor a
        // final answer. Show a spinner until the tool completes.
        ToolRunningSpinner(title: "Answer", accent: .tronInfo, tint: tint, actionText: "Fetching page...")
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("WebFetch - Success") {
    WebFetchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_wf1",
            toolName: "WebFetch",
            normalizedName: "webfetch",
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            displayName: "Web Fetch",
            summary: "docs.anthropic.com",
            status: .success,
            durationMs: 2500,
            arguments: "{\"url\": \"https://docs.anthropic.com/en/docs/about-claude/models\", \"prompt\": \"What models are available?\"}",
            result: """
            Claude has three main model families:

            1. **Claude 4.5 Sonnet** - Best balance of intelligence and speed
            2. **Claude Opus 4.6** - Most capable for complex reasoning
            3. **Claude 4.5 Haiku** - Fast and cost-effective

            All models support the Messages API with streaming, tool use, and vision.

            Source: https://docs.anthropic.com/en/docs/about-claude/models
            Title: Claude Models - Anthropic Documentation
            """,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebFetch - Error 404") {
    WebFetchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_wf2",
            toolName: "WebFetch",
            normalizedName: "webfetch",
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            displayName: "Web Fetch",
            summary: "example.com",
            status: .error,
            durationMs: 350,
            arguments: "{\"url\": \"https://example.com/nonexistent\", \"prompt\": \"Read this page\"}",
            result: "Error: HTTP 404 - Page not found",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebFetch - Running") {
    WebFetchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_wf4",
            toolName: "WebFetch",
            normalizedName: "webfetch",
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            displayName: "Web Fetch",
            summary: "github.com",
            status: .running,
            durationMs: nil,
            arguments: "{\"url\": \"https://github.com/anthropics/claude-code\", \"prompt\": \"What is this project?\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebFetch - Raw POST") {
    WebFetchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_wf7",
            toolName: "WebFetch",
            normalizedName: "webfetch",
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            displayName: "Web Fetch",
            summary: "POST api.example.com",
            status: .success,
            durationMs: 450,
            arguments: "{\"url\": \"https://api.example.com/items\", \"method\": \"POST\", \"body\": {\"name\": \"New Item\"}}",
            result: "HTTP 201 https://api.example.com/items\n\n{\"id\": 42, \"name\": \"New Item\", \"created\": true}",
            isResultTruncated: false
        )
    )
}
#endif
