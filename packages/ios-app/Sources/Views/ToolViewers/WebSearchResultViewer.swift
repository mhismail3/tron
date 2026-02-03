import SwiftUI

/// Displays WebSearch results as a list of search results with clickable links
struct WebSearchResultViewer: View {
    let result: String
    let arguments: String
    @Binding var isExpanded: Bool

    private var parsedResults: WebSearchParsedResults {
        WebSearchParsedResults(from: result, arguments: arguments)
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
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
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
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronInfo)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                // URL
                Text(result.displayUrl)
                    .font(TronTypography.codeCaption)
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
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .regular))
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
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .regular))
                .foregroundStyle(.tronWarning)
        }
        .padding(8)
        .background(Color.tronWarning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Data Models

struct WebSearchParsedResults {
    let query: String
    let results: [SearchResult]
    let totalResults: Int?
    let error: String?

    init(from result: String, arguments: String) {
        // Extract query from arguments
        if let match = arguments.firstMatch(of: /"query"\s*:\s*"([^"]+)"/) {
            self.query = String(match.1)
                .replacingOccurrences(of: "\\", with: "")
        } else {
            self.query = ""
        }

        // Check for error
        if result.contains("Error:") || result.contains("\"error\"") {
            self.error = Self.extractError(from: result)
            self.results = []
            self.totalResults = nil
            return
        }

        self.error = nil
        self.results = Self.parseResults(from: result)
        self.totalResults = Self.extractTotalResults(from: result) ?? self.results.count
    }

    private static func extractError(from result: String) -> String {
        if let match = result.firstMatch(of: /Error:\s*(.+)/) {
            return String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = result.firstMatch(of: /"error"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return "Search failed"
    }

    private static func extractTotalResults(from result: String) -> Int? {
        if let match = result.firstMatch(of: /Found\s+(\d+)\s+results?/) {
            return Int(match.1)
        }
        if let match = result.firstMatch(of: /"totalResults"\s*:\s*(\d+)/) {
            return Int(match.1)
        }
        return nil
    }

    private static func parseResults(from result: String) -> [SearchResult] {
        var results: [SearchResult] = []

        // Try markdown format: "1. **Title**\n   URL\n   Snippet"
        let lines = result.components(separatedBy: "\n")
        var currentTitle = ""
        var currentUrl = ""
        var currentSnippet = ""
        var inResult = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check for numbered title with markdown bold
            if let match = trimmed.firstMatch(of: /^(\d+)\.\s+\*\*(.+?)\*\*$/) {
                // Save previous result if any
                if !currentTitle.isEmpty && !currentUrl.isEmpty {
                    results.append(SearchResult(
                        title: currentTitle,
                        url: currentUrl,
                        snippet: currentSnippet.trimmingCharacters(in: .whitespacesAndNewlines),
                        age: nil
                    ))
                }

                currentTitle = String(match.2)
                currentUrl = ""
                currentSnippet = ""
                inResult = true
            }
            // Check for numbered title without markdown
            else if let match = trimmed.firstMatch(of: /^(\d+)\.\s+(.+)$/) {
                // Could be title or could be continuation
                if !inResult {
                    // Save previous result if any
                    if !currentTitle.isEmpty && !currentUrl.isEmpty {
                        results.append(SearchResult(
                            title: currentTitle,
                            url: currentUrl,
                            snippet: currentSnippet.trimmingCharacters(in: .whitespacesAndNewlines),
                            age: nil
                        ))
                    }

                    currentTitle = String(match.2)
                    currentUrl = ""
                    currentSnippet = ""
                    inResult = true
                }
            }
            // Check for URL
            else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                currentUrl = trimmed
            }
            // Check for URL: prefix
            else if trimmed.hasPrefix("URL:") {
                currentUrl = trimmed.replacingOccurrences(of: "URL:", with: "").trimmingCharacters(in: .whitespaces)
            }
            // Otherwise it's snippet content
            else if inResult && !trimmed.isEmpty && currentUrl.isEmpty == false {
                if currentSnippet.isEmpty {
                    currentSnippet = trimmed
                } else {
                    currentSnippet += " " + trimmed
                }
            }
            // Snippet before URL found
            else if inResult && !trimmed.isEmpty && !currentTitle.isEmpty {
                // This might be the URL on same line as title or snippet
                if trimmed.hasPrefix("http") {
                    currentUrl = trimmed
                }
            }
        }

        // Don't forget the last result
        if !currentTitle.isEmpty && !currentUrl.isEmpty {
            results.append(SearchResult(
                title: currentTitle,
                url: currentUrl,
                snippet: currentSnippet.trimmingCharacters(in: .whitespacesAndNewlines),
                age: nil
            ))
        }

        return results
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
        let shortPath = path.count > 30 ? String(path.prefix(27)) + "..." : path
        return host + shortPath
    }
}

// MARK: - Preview

#Preview("WebSearch Results") {
    ScrollView {
        VStack(spacing: 16) {
            WebSearchResultViewer(
                result: """
                Found 3 results for 'Swift async await':

                1. **Swift Concurrency - Apple Developer**
                   https://developer.apple.com/documentation/swift/concurrency
                   Learn about Swift's modern approach to writing concurrent and asynchronous code.

                2. **Async/Await in Swift - Swift by Sundell**
                   https://www.swiftbysundell.com/articles/async-await-in-swift/
                   A comprehensive guide to using async/await in Swift applications.

                3. **WWDC21: Meet async/await in Swift**
                   https://developer.apple.com/videos/play/wwdc2021/10132/
                   Watch the introduction of async/await at WWDC 2021.
                """,
                arguments: "{\"query\": \"Swift async await\"}",
                isExpanded: .constant(false)
            )

            WebSearchResultViewer(
                result: "Error: Rate limit exceeded - try again later",
                arguments: "{\"query\": \"test query\"}",
                isExpanded: .constant(false)
            )

            WebSearchResultViewer(
                result: "Found 0 results for 'xyznonexistentquery123'",
                arguments: "{\"query\": \"xyznonexistentquery123\"}",
                isExpanded: .constant(false)
            )
        }
        .padding()
    }
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
