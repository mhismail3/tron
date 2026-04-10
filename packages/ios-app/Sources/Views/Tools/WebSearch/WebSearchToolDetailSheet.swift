import SwiftUI

// MARK: - WebSearch Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for WebSearch tool results.
/// Shows the search query, numbered results with titles, URLs, and snippets,
/// with glass-effect containers and structured error/empty states.
@available(iOS 26.0, *)
struct WebSearchToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private var tint: TintedColors {
        TintedColors(accent: .tronInfo, colorScheme: colorScheme)
    }

    private var query: String {
        ToolArgumentParser.query(from: data.arguments)
    }

    private var parsed: WebSearchParsedResults {
        WebSearchParsedResults(details: data.details, arguments: data.arguments)
    }

    private var endpoint: String? {
        ToolArgumentParser.string("endpoint", from: data.arguments)
    }

    private var freshness: String? {
        ToolArgumentParser.string("freshness", from: data.arguments)
    }

    private var allowedDomains: [String]? {
        ToolArgumentParser.stringArray("allowedDomains", from: data.arguments)
            ?? ToolArgumentParser.stringArray("allowed_domains", from: data.arguments)
    }

    private var isTruncated: Bool {
        data.isResultTruncated
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Web Search",
            iconName: "magnifyingglass.circle",
            accent: .tronInfo,
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
                querySection
                    .sheetSection()
                statusRow
                    .sheetSection()

                switch data.status {
                case .success:
                    if let error = parsed.error {
                        searchErrorSection(error)
                            .sheetSection()
                    } else if parsed.results.isEmpty {
                        noResultsSection
                            .sheetSection()
                    } else {
                        resultsSection
                            .sheetSection()
                    }
                case .error:
                    let message = WebSearchDetailParser.errorMessage(from: data.details)
                        ?? data.result
                        ?? "Search failed"
                    searchErrorSection(message)
                        .sheetSection()
                case .running:
                    runningSection
                        .sheetSection()
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Query Section

    private var querySection: some View {
        ToolDetailSection(title: "Query", accent: .tronInfo, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                Text(query)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(tint.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    if let ep = endpoint, ep != "web" {
                        HStack(spacing: 4) {
                            Image(systemName: endpointIcon(ep))
                                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                                .foregroundStyle(tint.subtle)
                            Text(ep.capitalized)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.secondary)
                        }
                    }

                    if let fresh = freshness {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                                .foregroundStyle(tint.subtle)
                            Text(freshnessLabel(fresh))
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.secondary)
                        }
                    }

                    if let domains = allowedDomains, !domains.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                                .foregroundStyle(tint.subtle)
                            Text(domains.joined(separator: ", "))
                                .font(TronTypography.codeContent)
                                .foregroundStyle(tint.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            if let total = parsed.totalResults, total > 0 {
                ToolInfoPill(icon: "text.line.first.and.arrowtriangle.forward", label: "\(total) results", color: .tronInfo)
            }
            if isTruncated {
                ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
            }
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: data.result ?? "", accent: .tronInfo)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parsed.results.enumerated()), id: \.offset) { index, result in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.tronInfo.opacity(0.1))
                            .frame(height: 1)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                    }
                    searchResultRow(result, index: index + 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .sectionFill(.tronInfo, compact: parsed.results.count < 100)
        }
    }

    private func searchResultRow(_ result: SearchResult, index: Int) -> some View {
        Button {
            if let url = URL(string: result.url) {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index).")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(tint.subtle)
                        .frame(width: 20, alignment: .trailing)

                    Text(result.title)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronInfo)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Text(result.displayUrl)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(.tronEmerald)
                    .lineLimit(1)
                    .padding(.leading, 26)

                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 26)
                }

                if let age = result.age {
                    Text(age)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(tint.subtle)
                        .padding(.leading, 26)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - No Results Section

    private var noResultsSection: some View {
        ToolEmptyState(title: "Results", icon: "magnifyingglass", message: "No results found", accent: .tronInfo, tint: tint, subtitle: "Query: \"\(query)\"")
    }

    // MARK: - Error Section

    private func searchErrorSection(_ errorMessage: String) -> some View {
        ToolClassifiedErrorSection(
            errorMessage: errorMessage,
            classification: WebSearchDetailParser.classify(details: data.details),
            colorScheme: colorScheme
        )
    }

    // MARK: - Running Section

    private var runningSection: some View {
        ToolRunningSpinner(title: "Results", accent: .tronInfo, tint: tint, actionText: "Searching the web...")
    }

    // MARK: - Helpers

    private func endpointIcon(_ endpoint: String) -> String {
        switch endpoint {
        case "news": return "newspaper"
        case "images": return "photo"
        case "videos": return "play.rectangle"
        default: return "globe"
        }
    }

    private func freshnessLabel(_ freshness: String) -> String {
        switch freshness {
        case "pd": return "Past day"
        case "pw": return "Past week"
        case "pm": return "Past month"
        case "py": return "Past year"
        default: return freshness
        }
    }
}

// MARK: - WebSearch Detail Parser

/// Error classification for WebSearch detail sheet.
///
/// Reads structured fields written by the server
/// (`packages/agent/src/tools/web/web_search.rs`). The server emits
/// `details.error` (message) and `details.errorClass` (enum-like string),
/// so iOS does not scan any free-form error text.
enum WebSearchDetailParser {

    /// Pull the server-provided error message from details.
    static func errorMessage(from details: [String: AnyCodable]?) -> String? {
        details?.string("error")
    }

    /// Pull the server-provided error class from details.
    static func errorClass(from details: [String: AnyCodable]?) -> String? {
        details?.string("errorClass")
    }

    /// Build an `ErrorClassification` from structured server details.
    static func classify(details: [String: AnyCodable]?) -> ErrorClassification {
        switch errorClass(from: details) {
        case "rate_limited":
            return ErrorClassification(
                icon: "clock.badge.exclamationmark",
                title: "Rate Limited",
                code: "429",
                suggestion: "Too many search requests. Try again in a moment."
            )
        case "api_key":
            return ErrorClassification(
                icon: "key.fill",
                title: "API Key Error",
                code: "401",
                suggestion: "The search API key is invalid or expired."
            )
        case "quota":
            return ErrorClassification(
                icon: "chart.bar.xaxis",
                title: "Quota Exceeded",
                code: nil,
                suggestion: "The monthly search quota has been reached."
            )
        case "timeout":
            return ErrorClassification(
                icon: "clock.arrow.circlepath",
                title: "Search Timed Out",
                code: nil,
                suggestion: "The search took too long to respond. Try again."
            )
        case "invalid_query":
            return ErrorClassification(
                icon: "exclamationmark.triangle.fill",
                title: "Invalid Query",
                code: nil,
                suggestion: "The search query is invalid or too long."
            )
        case "network":
            return ErrorClassification(
                icon: "wifi.exclamationmark",
                title: "Network Error",
                code: nil,
                suggestion: "Could not reach the search service."
            )
        default:
            return ErrorClassification(
                icon: "exclamationmark.triangle.fill",
                title: "Search Failed",
                code: nil,
                suggestion: "An error occurred while searching the web."
            )
        }
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("WebSearch - Results") {
    WebSearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ws1",
            toolName: "WebSearch",
            normalizedName: "websearch",
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            displayName: "Web Search",
            summary: "\"Swift concurrency\"",
            status: .success,
            durationMs: 850,
            arguments: "{\"query\": \"Swift concurrency async await\"}",
            result: "1. [Swift Concurrency - Apple Developer](https://developer.apple.com/documentation/swift/concurrency)\n   Learn about Swift's modern approach to writing concurrent and asynchronous code with structured concurrency.\n\n2. [Async/Await in Swift - Swift by Sundell](https://www.swiftbysundell.com/articles/async-await-in-swift/)\n   A comprehensive guide to using async/await patterns in Swift applications.\n\n3. [WWDC21: Meet async/await in Swift](https://developer.apple.com/videos/play/wwdc2021/10132/)\n   Watch Apple's introduction of async/await at WWDC 2021.",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebSearch - No Results") {
    WebSearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ws2",
            toolName: "WebSearch",
            normalizedName: "websearch",
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            displayName: "Web Search",
            summary: "\"xyznonexistent\"",
            status: .success,
            durationMs: 400,
            arguments: "{\"query\": \"xyznonexistentquery123456\"}",
            result: "Found 0 results for 'xyznonexistentquery123456'",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebSearch - Rate Limited") {
    WebSearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ws3",
            toolName: "WebSearch",
            normalizedName: "websearch",
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            displayName: "Web Search",
            summary: "\"test query\"",
            status: .error,
            durationMs: 120,
            arguments: "{\"query\": \"test query\"}",
            result: "Error: Rate limit exceeded - try again later",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebSearch - Running") {
    WebSearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ws4",
            toolName: "WebSearch",
            normalizedName: "websearch",
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            displayName: "Web Search",
            summary: "\"latest news\"",
            status: .running,
            durationMs: nil,
            arguments: "{\"query\": \"latest news today\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebSearch - With Filters") {
    WebSearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ws5",
            toolName: "WebSearch",
            normalizedName: "websearch",
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            displayName: "Web Search",
            summary: "\"SwiftUI\"",
            status: .success,
            durationMs: 600,
            arguments: "{\"query\": \"SwiftUI tutorials\", \"freshness\": \"pw\", \"allowedDomains\": [\"developer.apple.com\", \"swift.org\"]}",
            result: "1. [SwiftUI Tutorials - Apple Developer](https://developer.apple.com/tutorials/swiftui)\n   Follow a series of guided tutorials to learn to make apps using SwiftUI.\n\n2. [Swift.org - SwiftUI Resources](https://swift.org/getting-started/swiftui/)\n   Official SwiftUI resources and documentation from the Swift project.",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("WebSearch - News Endpoint") {
    WebSearchToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ws6",
            toolName: "WebSearch",
            normalizedName: "websearch",
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            displayName: "Web Search",
            summary: "\"AI news\"",
            status: .success,
            durationMs: 450,
            arguments: "{\"query\": \"AI news\", \"endpoint\": \"news\", \"freshness\": \"pd\"}",
            result: "1. [OpenAI Announces New Model](https://techcrunch.com/2026/02/15/openai-new-model)\n   OpenAI has released a new model with improved reasoning capabilities.\n\n2. [Google DeepMind Research Update](https://blog.google/technology/ai/deepmind-update)\n   Latest research from Google DeepMind on multimodal AI systems.",
            isResultTruncated: false
        )
    )
}
#endif
