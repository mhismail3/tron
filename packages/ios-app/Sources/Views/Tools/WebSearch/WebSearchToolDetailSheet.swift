import SwiftUI

// MARK: - WebSearch Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for WebSearch tool results.
/// Shows the search query, numbered results with titles, URLs, and snippets,
/// with glass-effect containers and structured error/empty states.
@available(iOS 26.0, *)
struct WebSearchToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    private var tint: TintedColors {
        TintedColors(accent: .tronSlate, colorScheme: colorScheme)
    }

    private var query: String {
        ToolArgumentParser.query(from: data.arguments)
    }

    private var parsed: WebSearchParsedResults {
        WebSearchParsedResults(from: data.result ?? data.streamingOutput ?? "", arguments: data.arguments)
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
                        UIPasteboard.general.string = data.result ?? ""
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.tronSlate.opacity(0.6))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.tronInfo)
                        Text("Web Search")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronSlate)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronSlate)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronSlate)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    querySection
                        .padding(.horizontal)
                    statusRow
                        .padding(.horizontal)

                    switch data.status {
                    case .success:
                        if let error = parsed.error {
                            searchErrorSection(error)
                                .padding(.horizontal)
                        } else if parsed.results.isEmpty {
                            noResultsSection
                                .padding(.horizontal)
                        } else {
                            resultsSection
                                .padding(.horizontal)
                        }
                    case .error:
                        if let result = data.result {
                            searchErrorSection(WebSearchDetailParser.extractError(from: result))
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
                                .font(.system(size: 11))
                                .foregroundStyle(tint.subtle)
                            Text(ep.capitalized)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.secondary)
                        }
                    }

                    if let fresh = freshness {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 11))
                                .foregroundStyle(tint.subtle)
                            Text(freshnessLabel(fresh))
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(tint.secondary)
                        }
                    }

                    if let domains = allowedDomains, !domains.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 11))
                                .foregroundStyle(tint.subtle)
                            Text(domains.joined(separator: ", "))
                                .font(TronTypography.codeCaption)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: data.status)

                if let ms = data.durationMs {
                    ToolDurationBadge(durationMs: ms)
                }

                if let total = parsed.totalResults, total > 0 {
                    ToolInfoPill(icon: "text.line.first.and.arrowtriangle.forward", label: "\(total) results", color: .tronInfo)
                }

                if isTruncated {
                    ToolInfoPill(icon: "scissors", label: "Truncated", color: .tronAmber)
                }
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

                Button {
                    UIPasteboard.general.string = data.result ?? ""
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronSlate.opacity(0.6))
                }
            }

            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color.tronInfo)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(parsed.results.enumerated()), id: \.offset) { index, result in
                        if index > 0 {
                            Divider()
                                .background(Color.tronSlate.opacity(0.08))
                                .padding(.horizontal, 8)
                        }
                        searchResultRow(result, index: index + 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .sectionFill(.tronSlate)
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
                    .font(TronTypography.codeCaption)
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
        ToolDetailSection(title: "Results", accent: .tronSlate, tint: tint) {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(tint.subtle)
                Text("No results found")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
                Text("Query: \"\(query)\"")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.subtle.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Error Section

    private func searchErrorSection(_ errorMessage: String) -> some View {
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
        let errorInfo = WebSearchDetailParser.classifyError(errorMessage)

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
            let streaming = WebSearchParsedResults(from: output, arguments: data.arguments)
            if !streaming.results.isEmpty {
                streamingResultsSection(streaming)
            } else {
                searchingSpinner
            }
        } else {
            searchingSpinner
        }
    }

    private var searchingSpinner: some View {
        ToolDetailSection(title: "Results", accent: .tronSlate, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.tronInfo)
                    .scaleEffect(1.1)
                Text("Searching the web...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private func streamingResultsSection(_ streaming: WebSearchParsedResults) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
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

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(streaming.results.enumerated()), id: \.offset) { index, result in
                        if index > 0 {
                            Divider()
                                .background(Color.tronSlate.opacity(0.08))
                                .padding(.horizontal, 8)
                        }
                        searchResultRow(result, index: index + 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .sectionFill(.tronSlate)
        }
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
enum WebSearchDetailParser {

    static func extractError(from result: String) -> String {
        if let match = result.firstMatch(of: /Error:\s*(.+)/) {
            return String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = result.firstMatch(of: /"error"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return result
    }

    static func classifyError(_ message: String) -> (icon: String, title: String, code: String?, suggestion: String) {
        let lower = message.lowercased()

        if lower.contains("rate limit") || lower.contains("429") {
            return ("clock.badge.exclamationmark", "Rate Limited", "429",
                    "Too many search requests. Try again in a moment.")
        }
        if lower.contains("api key") || lower.contains("authentication") || lower.contains("401") {
            return ("key.fill", "API Key Error", "401",
                    "The search API key is invalid or expired.")
        }
        if lower.contains("quota") || lower.contains("exceeded") {
            return ("chart.bar.xaxis", "Quota Exceeded", nil,
                    "The monthly search quota has been reached.")
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return ("clock.arrow.circlepath", "Search Timed Out", nil,
                    "The search took too long to respond. Try again.")
        }
        if lower.contains("invalid") && lower.contains("query") {
            return ("exclamationmark.triangle.fill", "Invalid Query", nil,
                    "The search query is invalid or too long.")
        }

        return ("exclamationmark.triangle.fill", "Search Failed", nil,
                "An error occurred while searching the web.")
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
            displayName: "Search",
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
            displayName: "Search",
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
            displayName: "Search",
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
            displayName: "Search",
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
            displayName: "Search",
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
            displayName: "Search",
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
