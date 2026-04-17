import SwiftUI

/// Displays WebSearch results as a list of search results with clickable links.
///
/// Reads structured results from `tool.details.results` (server-provided).
/// Falls back to empty state if details are missing.
struct WebSearchResultViewer: View {
    let details: [String: AnyCodable]?
    let arguments: String
    @Binding var isExpanded: Bool

    private var parsedResults: WebSearchParsedResults {
        WebSearchParsedResults(details: details, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Query Header
            QueryHeader(query: parsedResults.query, totalResults: parsedResults.totalResults)

            // Error or Results
            if let error = parsedResults.error {
                WebSearchErrorBanner(message: error)
            } else if parsedResults.results.isEmpty {
                NoResultsView()
            } else {
                ResultsList(results: parsedResults.results, isExpanded: $isExpanded)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Subviews

private struct QueryHeader: View {
    let query: String
    let totalResults: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronInfo)
                Text("Search: \"\(query)\"")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(2)
            }

            if let total = totalResults, total > 0 {
                Text("\(total) results found")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
            }
        }
    }
}

private struct ResultsList: View {
    let results: [SearchResult]
    @Binding var isExpanded: Bool

    private var displayResults: [SearchResult] {
        if isExpanded {
            return results
        } else {
            return Array(results.prefix(5))
        }
    }

    private var needsExpansion: Bool {
        results.count > 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(displayResults.enumerated()), id: \.offset) { index, result in
                SearchResultRow(result: result, index: index + 1)

                if index < displayResults.count - 1 {
                    Divider()
                        .background(Color.tronBorder.opacity(0.3))
                }
            }

            if needsExpansion {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded ? "Show less" : "Show all \(results.count) results")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronInfo)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let index: Int
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: result.url) {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                // Title with index
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index).")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                        .frame(width: 16, alignment: .trailing)

                    Text(result.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronInfo)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                // URL
                Text(result.displayUrl)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(.tronEmerald)
                    .lineLimit(1)
                    .padding(.leading, 22)

                // Snippet
                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                        .padding(.leading, 22)
                }

                // Age
                if let age = result.age {
                    Text(age)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                        .padding(.leading, 22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NoResultsView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
            Text("No results found")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .regular))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct WebSearchErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronWarning)
            Text(message)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .regular))
                .foregroundStyle(.tronWarning)
        }
        .padding(8)
        .background(Color.tronWarning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Data Models

/// Structured WebSearch results, sourced from server-provided `tool.details`.
///
/// The server (`packages/agent/src/tools/web/web_search.rs`) populates
/// `details.results` with an array of `{title, url, snippet, age?}` objects
/// and `details.error` / `details.errorClass` on failure. iOS reads these
/// directly — no text parsing.
struct WebSearchParsedResults {
    let query: String
    let results: [SearchResult]
    let totalResults: Int?
    let error: String?

    init(details: [String: AnyCodable]?, arguments: String) {
        self.query = ToolArgumentParser.query(from: arguments)

        if let errorMessage = details?["error"]?.value as? String {
            self.error = errorMessage
            self.results = []
            self.totalResults = nil
            return
        }

        self.error = nil
        self.results = Self.decodeResults(from: details)
        if let count = details?["resultCount"]?.value as? Int {
            self.totalResults = count
        } else if let count = details?["resultCount"]?.value as? Double {
            self.totalResults = Int(count)
        } else {
            self.totalResults = self.results.count
        }
    }

    private static func decodeResults(from details: [String: AnyCodable]?) -> [SearchResult] {
        guard let raw = details?["results"]?.value as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let title = dict["title"] as? String,
                  let url = dict["url"] as? String
            else { return nil }
            let snippet = (dict["snippet"] as? String) ?? ""
            let age = dict["age"] as? String
            return SearchResult(title: title, url: url, snippet: snippet, age: age)
        }
    }
}

struct SearchResult {
    let title: String
    let url: String
    let snippet: String
    let age: String?

    var displayUrl: String {
        guard let urlObj = URL(string: url), let host = urlObj.host else { return url }
        let path = urlObj.path
        let shortPath = path.truncated(to: 30)
        return host + shortPath
    }
}

// MARK: - Preview

#if DEBUG
#Preview("WebSearch Results") {
    let sampleResults: [[String: Any]] = [
        [
            "title": "Swift Concurrency - Apple Developer",
            "url": "https://developer.apple.com/documentation/swift/concurrency",
            "snippet": "Learn about Swift's modern approach to writing concurrent and asynchronous code.",
        ],
        [
            "title": "Async/Await in Swift - Swift by Sundell",
            "url": "https://www.swiftbysundell.com/articles/async-await-in-swift/",
            "snippet": "A comprehensive guide to using async/await in Swift applications.",
        ],
    ]
    let okDetails: [String: AnyCodable] = [
        "results": AnyCodable(sampleResults),
        "resultCount": AnyCodable(sampleResults.count),
    ]
    let errDetails: [String: AnyCodable] = [
        "error": AnyCodable("Brave API error: HTTP 429"),
        "errorClass": AnyCodable("rate_limited"),
    ]
    return ScrollView {
        VStack(spacing: 16) {
            WebSearchResultViewer(
                details: okDetails,
                arguments: "{\"query\": \"Swift async await\"}",
                isExpanded: .constant(false)
            )
            WebSearchResultViewer(
                details: errDetails,
                arguments: "{\"query\": \"test query\"}",
                isExpanded: .constant(false)
            )
            WebSearchResultViewer(
                details: ["results": AnyCodable([] as [[String: Any]]), "resultCount": AnyCodable(0)],
                arguments: "{\"query\": \"xyznonexistentquery123\"}",
                isExpanded: .constant(false)
            )
        }
        .padding()
    }
    .background(Color.tronBackground)
}
#endif
