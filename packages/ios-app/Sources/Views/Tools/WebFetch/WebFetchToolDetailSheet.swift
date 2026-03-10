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

    private var domain: String {
        ToolArgumentParser.extractDomain(from: url)
    }

    private var parsed: WebFetchParsedResult {
        WebFetchParsedResult(from: data.result ?? data.streamingOutput ?? "", arguments: data.arguments)
    }

    private var isTruncated: Bool {
        data.isResultTruncated || (data.result?.contains("[Output truncated") == true)
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Web Fetch",
            iconName: "arrow.down.doc",
            accent: .tronInfo,
            copyContent: url
        ) {
            contentBody
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                sourceSection
                    .padding(.horizontal)

                if !prompt.isEmpty {
                    promptSection
                        .padding(.horizontal)
                }

                statusRow
                    .padding(.horizontal)

                switch data.status {
                case .success:
                    if let error = parsed.error {
                        fetchErrorSection(error)
                            .padding(.horizontal)
                    } else if !parsed.answer.isEmpty {
                        answerSection
                            .padding(.horizontal)
                    } else {
                        emptyResultSection
                            .padding(.horizontal)
                    }
                case .error:
                    if let result = data.result {
                        fetchErrorSection(WebFetchDetailParser.extractError(from: result))
                            .padding(.horizontal)
                    }
                case .running:
                    runningSection
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Source Section

    private var sourceSection: some View {
        ToolDetailSection(title: "Source", accent: .tronInfo, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle))
                        .foregroundStyle(.tronInfo)

                    if let source = parsed.source, !source.title.isEmpty {
                        Text(source.title)
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(tint.name)
                            .lineLimit(2)
                    } else {
                        Text(domain)
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(tint.name)
                            .lineLimit(1)
                    }

                    Spacer()
                }

                if !url.isEmpty {
                    Text(url)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Prompt Section

    private var promptSection: some View {
        ToolDetailSection(title: "Prompt", accent: .tronInfo, tint: tint) {
            Text(prompt)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            if parsed.isCached {
                ToolInfoPill(icon: "arrow.triangle.2.circlepath", label: "Cached", color: .tronEmerald)
            }
            if isTruncated {
                ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
            }
        }
    }

    // MARK: - Answer Section

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Answer")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                Button {
                    UIPasteboard.general.string = parsed.answer
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronInfo.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                let blocks = MarkdownBlockParser.parse(parsed.answer)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, textColor: tint.body)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .sectionFill(.tronInfo)
        }
    }

    // MARK: - Empty Result Section

    private var emptyResultSection: some View {
        ToolDetailSection(title: "Answer", accent: .tronInfo, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(TronTypography.sans(size: 28))
                    .foregroundStyle(tint.subtle)
                Text("No content returned")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Error Section

    private func fetchErrorSection(_ errorMessage: String) -> some View {
        let classification = WebFetchDetailParser.classifyError(errorMessage)

        return ToolClassifiedErrorSection(
            errorMessage: errorMessage,
            classification: classification,
            colorScheme: colorScheme
        ) {
            if !url.isEmpty {
                let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
                Text(url)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(errorTint.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Running Section

    @ViewBuilder
    private var runningSection: some View {
        if let output = data.streamingOutput, !output.isEmpty {
            let streamParsed = WebFetchParsedResult(from: output, arguments: data.arguments)
            if !streamParsed.answer.isEmpty {
                streamingAnswerSection(streamParsed.answer)
            } else {
                ToolRunningSpinner(title: "Answer", accent: .tronInfo, tint: tint, actionText: "Fetching page...")
            }
        } else {
            ToolRunningSpinner(title: "Answer", accent: .tronInfo, tint: tint, actionText: "Fetching page...")
        }
    }

    private func streamingAnswerSection(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Answer")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.tronInfo)
            }

            VStack(alignment: .leading, spacing: 8) {
                let blocks = MarkdownBlockParser.parse(answer)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, textColor: tint.body)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .sectionFill(.tronInfo)
        }
    }
}

// MARK: - WebFetch Detail Parser

/// Parsing and error classification for WebFetch detail sheet.
enum WebFetchDetailParser {

    /// Extract just the error message from a result string.
    static func extractError(from result: String) -> String {
        if result.hasPrefix("Error:") {
            return String(result.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = result.firstMatch(of: /"error"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return result
    }

    /// Detect if the result indicates a cached response.
    static func isCached(_ result: String) -> Bool {
        result.contains("fromCache") && result.contains("true")
    }

    /// Classify an error message into a structured type with icon, title, code, suggestion.
    static func classifyError(_ message: String) -> ErrorClassification {
        let lower = message.lowercased()

        if lower.contains("404") || lower.contains("not found") {
            return ErrorClassification(icon: "questionmark.folder", title: "Page Not Found", code: "HTTP 404",
                    suggestion: "The page may have been moved or deleted. Check the URL.")
        }
        if lower.contains("403") || lower.contains("forbidden") {
            return ErrorClassification(icon: "lock.fill", title: "Access Forbidden", code: "HTTP 403",
                    suggestion: "The server denied access to this page.")
        }
        if lower.contains("401") || lower.contains("unauthorized") {
            return ErrorClassification(icon: "lock.shield", title: "Unauthorized", code: "HTTP 401",
                    suggestion: "Authentication is required to access this page.")
        }
        if lower.contains("429") || lower.contains("rate limit") {
            return ErrorClassification(icon: "clock.badge.exclamationmark", title: "Rate Limited", code: "HTTP 429",
                    suggestion: "Too many requests. Try again in a moment.")
        }
        if lower.contains("500") || lower.contains("internal server") {
            return ErrorClassification(icon: "server.rack", title: "Server Error", code: "HTTP 500",
                    suggestion: "The remote server encountered an error.")
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return ErrorClassification(icon: "clock.arrow.circlepath", title: "Request Timed Out", code: nil,
                    suggestion: "The page took too long to respond. Try again later.")
        }
        if lower.contains("dns") || lower.contains("resolve") || lower.contains("no such host") {
            return ErrorClassification(icon: "wifi.slash", title: "DNS Error", code: nil,
                    suggestion: "Could not resolve the domain. Check the URL is correct.")
        }
        if lower.contains("ssl") || lower.contains("certificate") || lower.contains("tls") {
            return ErrorClassification(icon: "lock.trianglebadge.exclamationmark", title: "SSL Error", code: nil,
                    suggestion: "There was a problem with the site's security certificate.")
        }
        if lower.contains("redirect") {
            return ErrorClassification(icon: "arrow.triangle.turn.up.right.diamond", title: "Redirect Detected", code: nil,
                    suggestion: "The page redirected to a different host. Try fetching the redirect URL.")
        }
        if lower.contains("blocked") || lower.contains("denied") {
            return ErrorClassification(icon: "shield.slash", title: "Domain Blocked", code: nil,
                    suggestion: "This domain is blocked from being fetched.")
        }

        return ErrorClassification(icon: "exclamationmark.triangle.fill", title: "Fetch Failed", code: nil,
                suggestion: "An error occurred while fetching the page.")
    }
}

// MARK: - WebFetchParsedResult Extensions

extension WebFetchParsedResult {
    /// Whether the result came from cache.
    var isCached: Bool {
        WebFetchDetailParser.isCached(answer)
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
#Preview("WebFetch - Error Timeout") {
    WebFetchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_wf3",
            toolName: "WebFetch",
            normalizedName: "webfetch",
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            displayName: "Web Fetch",
            summary: "slow-site.com",
            status: .error,
            durationMs: 30000,
            arguments: "{\"url\": \"https://slow-site.com/data\", \"prompt\": \"Get the data\"}",
            result: "Error: Request timed out after 30 seconds",
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
#Preview("WebFetch - Rate Limited") {
    WebFetchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_wf5",
            toolName: "WebFetch",
            normalizedName: "webfetch",
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            displayName: "Web Fetch",
            summary: "api.example.com",
            status: .error,
            durationMs: 120,
            arguments: "{\"url\": \"https://api.example.com/data\", \"prompt\": \"Read API docs\"}",
            result: "Error: Rate limit exceeded (429) - try again later",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebFetch - No Prompt") {
    WebFetchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_wf6",
            toolName: "WebFetch",
            normalizedName: "webfetch",
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            displayName: "Web Fetch",
            summary: "news.ycombinator.com",
            status: .success,
            durationMs: 1800,
            arguments: "{\"url\": \"https://news.ycombinator.com\"}",
            result: "The top stories on Hacker News today include discussions about AI safety, a new programming language, and a startup funding announcement.",
            isResultTruncated: false
        )
    )
}
#endif
