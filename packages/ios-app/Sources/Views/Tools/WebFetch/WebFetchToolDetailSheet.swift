import SwiftUI

// MARK: - WebFetch Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for WebFetch tool results.
/// Shows the fetched URL, source metadata, the AI-generated answer,
/// and structured error states with glass-effect containers.
@available(iOS 26.0, *)
struct WebFetchToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
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
        NavigationStack {
            ZStack {
                contentBody
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.tronInfo.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(.tronInfo)
                        Text("Fetch")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronInfo)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronInfo)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronInfo)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        GeometryReader { geometry in
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
                .frame(width: geometry.size.width)
            }
        }
    }

    // MARK: - Source Section

    private var sourceSection: some View {
        ToolDetailSection(title: "Source", accent: .tronInfo, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 16))
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: data.status)

                if let ms = data.durationMs {
                    ToolDurationBadge(durationMs: ms)
                }

                if parsed.isCached {
                    ToolInfoPill(icon: "arrow.triangle.2.circlepath", label: "Cached", color: .tronEmerald)
                }

                if isTruncated {
                    ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
                }
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

            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color.tronInfo)
                    .frame(width: 3)

                Text(parsed.answer)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(tint.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .sectionFill(.tronInfo)
        }
    }

    // MARK: - Empty Result Section

    private var emptyResultSection: some View {
        ToolDetailSection(title: "Answer", accent: .tronInfo, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 28))
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
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
        let errorInfo = WebFetchDetailParser.classifyError(errorMessage)

        return ToolDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: errorInfo.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(.tronError)

                    Text(errorInfo.title)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronError)
                }

                if !url.isEmpty {
                    Text(url)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(errorTint.secondary)
                        .textSelection(.enabled)
                }

                if let code = errorInfo.code {
                    ToolInfoPill(icon: "exclamationmark.triangle", label: code, color: .tronError)
                }

                Text(errorInfo.suggestion)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(errorTint.subtle)
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
                fetchingSpinner
            }
        } else {
            fetchingSpinner
        }
    }

    private var fetchingSpinner: some View {
        ToolDetailSection(title: "Answer", accent: .tronInfo, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.tronInfo)
                    .scaleEffect(1.1)
                Text("Fetching page...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
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

            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color.tronInfo)
                    .frame(width: 3)

                Text(answer)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(tint.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
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
    static func classifyError(_ message: String) -> (icon: String, title: String, code: String?, suggestion: String) {
        let lower = message.lowercased()

        if lower.contains("404") || lower.contains("not found") {
            return ("questionmark.folder", "Page Not Found", "HTTP 404",
                    "The page may have been moved or deleted. Check the URL.")
        }
        if lower.contains("403") || lower.contains("forbidden") {
            return ("lock.fill", "Access Forbidden", "HTTP 403",
                    "The server denied access to this page.")
        }
        if lower.contains("401") || lower.contains("unauthorized") {
            return ("lock.shield", "Unauthorized", "HTTP 401",
                    "Authentication is required to access this page.")
        }
        if lower.contains("429") || lower.contains("rate limit") {
            return ("clock.badge.exclamationmark", "Rate Limited", "HTTP 429",
                    "Too many requests. Try again in a moment.")
        }
        if lower.contains("500") || lower.contains("internal server") {
            return ("server.rack", "Server Error", "HTTP 500",
                    "The remote server encountered an error.")
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return ("clock.arrow.circlepath", "Request Timed Out", nil,
                    "The page took too long to respond. Try again later.")
        }
        if lower.contains("dns") || lower.contains("resolve") || lower.contains("no such host") {
            return ("wifi.slash", "DNS Error", nil,
                    "Could not resolve the domain. Check the URL is correct.")
        }
        if lower.contains("ssl") || lower.contains("certificate") || lower.contains("tls") {
            return ("lock.trianglebadge.exclamationmark", "SSL Error", nil,
                    "There was a problem with the site's security certificate.")
        }
        if lower.contains("redirect") {
            return ("arrow.triangle.turn.up.right.diamond", "Redirect Detected", nil,
                    "The page redirected to a different host. Try fetching the redirect URL.")
        }
        if lower.contains("blocked") || lower.contains("denied") {
            return ("shield.slash", "Domain Blocked", nil,
                    "This domain is blocked from being fetched.")
        }

        return ("exclamationmark.triangle.fill", "Fetch Failed", nil,
                "An error occurred while fetching the page.")
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
            displayName: "Fetch",
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
            displayName: "Fetch",
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
            displayName: "Fetch",
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
            displayName: "Fetch",
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
            displayName: "Fetch",
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
            displayName: "Fetch",
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
