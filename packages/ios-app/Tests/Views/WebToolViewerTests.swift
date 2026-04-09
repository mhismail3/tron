import Testing
import Foundation
@testable import TronMobile

/// Tests for WebFetch and WebSearch result viewers.
///
/// Both viewers now consume server-provided `tool.details` directly — no
/// text parsing. Parsing logic is exercised by the parser tests in
/// `WebToolDetailSheetTests.swift`. This file pins the end-to-end wiring
/// and a handful of edge cases that are specific to the viewers.

// MARK: - WebSearch Result Parsing Tests


// MARK: - WebSearch Result Parsing Tests

@Suite("WebSearchParsedResults Tests")
struct WebSearchParsedResultsTests {

    // MARK: - Query Extraction

    // MARK: - Test Helpers

    private func makeDetails(results: [[String: Any]] = [], error: String? = nil, resultCount: Int? = nil) -> [String: AnyCodable] {
        var d: [String: AnyCodable] = [:]
        d["results"] = AnyCodable(results)
        if let error { d["error"] = AnyCodable(error) }
        if let resultCount { d["resultCount"] = AnyCodable(resultCount) }
        return d
    }

    @Test("Extracts query from arguments")
    func testExtractsQueryFromArguments() {
        let details = makeDetails()
        let arguments = "{\"query\": \"Swift async await tutorial\"}"

        let parsed = WebSearchParsedResults(details: details, arguments: arguments)

        #expect(parsed.query == "Swift async await tutorial")
    }

    // MARK: - Results Decoding

    @Test("Decodes structured results from details")
    func testDecodesStructuredResults() {
        let results: [[String: Any]] = [
            [
                "title": "TypeScript Documentation",
                "url": "https://www.typescriptlang.org/docs/",
                "snippet": "Official TypeScript documentation.",
            ],
            [
                "title": "Learn TypeScript - FreeCodeCamp",
                "url": "https://freecodecamp.org/typescript",
                "snippet": "Free online course.",
            ],
            [
                "title": "TypeScript Deep Dive",
                "url": "https://basarat.gitbook.io/typescript/",
                "snippet": "Comprehensive guide.",
            ],
        ]
        let details = makeDetails(results: results, resultCount: 3)
        let parsed = WebSearchParsedResults(details: details, arguments: "{\"query\": \"TypeScript\"}")

        #expect(parsed.results.count == 3)
        #expect(parsed.results[0].title == "TypeScript Documentation")
        #expect(parsed.results[0].url == "https://www.typescriptlang.org/docs/")
        #expect(parsed.results[0].snippet == "Official TypeScript documentation.")
        #expect(parsed.totalResults == 3)
    }

    @Test("Decodes age field when present")
    func testDecodesAgeField() {
        let results: [[String: Any]] = [[
            "title": "Breaking News",
            "url": "https://news.example/1",
            "snippet": "story",
            "age": "2h",
        ]]
        let parsed = WebSearchParsedResults(
            details: makeDetails(results: results),
            arguments: "{\"query\": \"news\"}"
        )
        #expect(parsed.results[0].age == "2h")
    }

    @Test("Decodes age as nil when missing")
    func testDecodesAgeMissing() {
        let results: [[String: Any]] = [[
            "title": "Page",
            "url": "https://example.com",
            "snippet": "text",
        ]]
        let parsed = WebSearchParsedResults(
            details: makeDetails(results: results),
            arguments: "{\"query\": \"x\"}"
        )
        #expect(parsed.results[0].age == nil)
    }

    // MARK: - Error Handling

    @Test("Reads server-provided error message")
    func testServerProvidedError() {
        let details = makeDetails(error: "Brave API error: HTTP 429")
        let parsed = WebSearchParsedResults(details: details, arguments: "{\"query\": \"test\"}")

        #expect(parsed.error == "Brave API error: HTTP 429")
        #expect(parsed.results.isEmpty)
    }

    @Test("When error present, results are suppressed even if present")
    func testErrorSuppressesResults() {
        var details: [String: AnyCodable] = makeDetails(error: "Quota exceeded")
        details["results"] = AnyCodable([["title": "x", "url": "y", "snippet": "z"]])
        let parsed = WebSearchParsedResults(details: details, arguments: "{\"query\": \"x\"}")
        #expect(parsed.error != nil)
        #expect(parsed.results.isEmpty)
    }

    // MARK: - No Results Handling

    @Test("Handles empty results")
    func testHandlesEmptyResults() {
        let parsed = WebSearchParsedResults(
            details: makeDetails(results: [], resultCount: 0),
            arguments: "{\"query\": \"xyznonexistent\"}"
        )

        #expect(parsed.results.isEmpty)
        #expect(parsed.totalResults == 0)
        #expect(parsed.error == nil)
    }

    // MARK: - Edge Cases

    @Test("Handles missing query in arguments")
    func testHandlesMissingQuery() {
        let parsed = WebSearchParsedResults(details: makeDetails(), arguments: "{}")
        #expect(parsed.query.isEmpty)
    }

    @Test("Handles nil details")
    func testHandlesNilDetails() {
        let parsed = WebSearchParsedResults(details: nil, arguments: "{\"query\": \"test\"}")
        #expect(parsed.results.isEmpty)
        #expect(parsed.error == nil)
        #expect(parsed.totalResults == 0)
    }

    @Test("Skips malformed result entries missing title or url")
    func testSkipsMalformedResults() {
        let results: [[String: Any]] = [
            ["title": "valid", "url": "https://a", "snippet": ""],
            ["title": "no-url"],
            ["url": "https://b"],
        ]
        let parsed = WebSearchParsedResults(
            details: makeDetails(results: results),
            arguments: "{\"query\": \"x\"}"
        )
        #expect(parsed.results.count == 1)
        #expect(parsed.results[0].title == "valid")
    }
}

// MARK: - SearchResult Display URL Tests

@Suite("SearchResult DisplayUrl Tests")
struct SearchResultDisplayUrlTests {

    @Test("DisplayUrl shows host and path")
    func testDisplayUrlShowsHostAndPath() {
        let result = SearchResult(
            title: "Test",
            url: "https://example.com/docs/guide",
            snippet: "Description",
            age: nil
        )

        #expect(result.displayUrl.contains("example.com"))
        #expect(result.displayUrl.contains("/docs/guide"))
    }

    @Test("DisplayUrl truncates long paths")
    func testDisplayUrlTruncatesLongPaths() {
        let result = SearchResult(
            title: "Test",
            url: "https://example.com/very/long/path/to/some/deeply/nested/page/document.html",
            snippet: "Description",
            age: nil
        )

        // Should be truncated with ellipsis
        #expect(result.displayUrl.count <= 50)
        #expect(result.displayUrl.contains("...") || result.displayUrl.count <= 40)
    }

    @Test("DisplayUrl handles invalid URL gracefully")
    func testDisplayUrlHandlesInvalidUrl() {
        let result = SearchResult(
            title: "Test",
            url: "not a valid url",
            snippet: "Description",
            age: nil
        )

        // Should return the original URL as fallback
        #expect(result.displayUrl == "not a valid url")
    }
}
