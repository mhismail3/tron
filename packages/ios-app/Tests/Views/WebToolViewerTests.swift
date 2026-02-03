import Testing
import Foundation
@testable import TronMobile

/// Tests for WebFetch and WebSearch result viewer parsing logic
/// Following TDD: These tests are written BEFORE the implementation

// MARK: - WebFetch Result Parsing Tests

@Suite("WebFetchParsedResult Tests")
struct WebFetchParsedResultTests {

    // MARK: - Success Response Parsing

    @Test("Parses answer from success response")
    func testParsesAnswerFromSuccessResponse() {
        let result = """
        Claude has three main model families: Claude 3.5, Claude 3, and Claude Instant.

        Source: https://docs.anthropic.com/overview
        Title: Overview - Anthropic Docs
        """
        let arguments = "{\"url\": \"https://docs.anthropic.com/overview\", \"prompt\": \"What models are available?\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.answer.contains("Claude has three main model families"))
        #expect(parsed.error == nil)
    }

    @Test("Extracts source URL from arguments")
    func testExtractsSourceUrlFromArguments() {
        let result = "Summary of the page content..."
        let arguments = "{\"url\": \"https://example.com/docs\", \"prompt\": \"Summarize\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.source != nil)
        #expect(parsed.source?.url == "https://example.com/docs")
    }

    @Test("Extracts source domain from URL")
    func testExtractsSourceDomainFromUrl() {
        let result = "Content summary..."
        let arguments = "{\"url\": \"https://www.example.com/path/to/page\", \"prompt\": \"Read\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.source != nil)
        #expect(parsed.source?.domain == "example.com")
    }

    @Test("Extracts title from result when present")
    func testExtractsTitleFromResult() {
        let result = """
        This is the main content.

        Source: https://example.com
        Title: Example Page Title
        """
        let arguments = "{\"url\": \"https://example.com\", \"prompt\": \"Read\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.source?.title == "Example Page Title")
    }

    @Test("Handles result without title gracefully")
    func testHandlesResultWithoutTitle() {
        let result = "Just the answer content without any metadata."
        let arguments = "{\"url\": \"https://example.com\", \"prompt\": \"What is this?\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.answer == "Just the answer content without any metadata.")
        #expect(parsed.source?.title == "" || parsed.source?.title == nil)
    }

    // MARK: - Error Response Parsing

    @Test("Parses error from Error: prefix format")
    func testParsesErrorWithPrefix() {
        let result = "Error: Failed to fetch URL - connection timeout"
        let arguments = "{\"url\": \"https://slow-site.com\", \"prompt\": \"Read\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.error != nil)
        #expect(parsed.error?.contains("Failed to fetch URL") == true)
        #expect(parsed.answer.isEmpty)
    }

    @Test("Parses error from JSON format")
    func testParsesErrorFromJson() {
        let result = "{\"error\": \"Domain blocked: localhost\", \"code\": \"DOMAIN_BLOCKED\"}"
        let arguments = "{\"url\": \"https://localhost/api\", \"prompt\": \"Read\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.error != nil)
        #expect(parsed.error?.contains("Domain blocked") == true)
    }

    @Test("Parses 404 error response")
    func testParses404Error() {
        let result = "Error: HTTP 404 - Page not found"
        let arguments = "{\"url\": \"https://example.com/nonexistent\", \"prompt\": \"Read\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.error != nil)
        #expect(parsed.error?.contains("404") == true)
    }

    // MARK: - Metadata Extraction

    @Test("Extracts subagent session ID when present")
    func testExtractsSubagentSessionId() {
        let result = """
        The answer to your question.

        ---
        subagentSessionId: sess_abc123xyz
        """
        let arguments = "{\"url\": \"https://example.com\", \"prompt\": \"What is this?\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.metadata?.subagentSessionId == "sess_abc123xyz")
    }

    @Test("Handles result without metadata")
    func testHandlesResultWithoutMetadata() {
        let result = "Simple answer without any metadata"
        let arguments = "{\"url\": \"https://example.com\", \"prompt\": \"Summarize\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.metadata?.subagentSessionId == nil)
    }

    // MARK: - Edge Cases

    @Test("Handles escaped JSON in arguments")
    func testHandlesEscapedJsonInArguments() {
        let result = "Content summary"
        let arguments = "{\"url\": \"https:\\/\\/example.com\\/path\", \"prompt\": \"Read\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.source?.url == "https://example.com/path")
    }

    @Test("Handles empty result string")
    func testHandlesEmptyResult() {
        let result = ""
        let arguments = "{\"url\": \"https://example.com\", \"prompt\": \"Read\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.answer.isEmpty)
        #expect(parsed.error == nil)
    }

    @Test("Handles result with only whitespace")
    func testHandlesWhitespaceResult() {
        let result = "   \n\n  "
        let arguments = "{\"url\": \"https://example.com\", \"prompt\": \"Read\"}"

        let parsed = WebFetchParsedResult(from: result, arguments: arguments)

        #expect(parsed.answer.isEmpty)
    }
}

// MARK: - WebSearch Result Parsing Tests

@Suite("WebSearchParsedResults Tests")
struct WebSearchParsedResultsTests {

    // MARK: - Query Extraction

    @Test("Extracts query from arguments")
    func testExtractsQueryFromArguments() {
        let result = "Found 10 results..."
        let arguments = "{\"query\": \"Swift async await tutorial\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.query == "Swift async await tutorial")
    }

    @Test("Handles escaped query in arguments")
    func testHandlesEscapedQuery() {
        let result = "Results..."
        let arguments = "{\"query\": \"React \\\"hooks\\\" guide\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.query.contains("React"))
    }

    // MARK: - Results Parsing

    @Test("Parses search results in markdown format")
    func testParsesMarkdownResults() {
        let result = """
        Found 3 results for 'TypeScript tutorial':

        1. **TypeScript Documentation**
           https://www.typescriptlang.org/docs/
           Official TypeScript documentation and tutorials.

        2. **Learn TypeScript - FreeCodeCamp**
           https://freecodecamp.org/typescript
           Free online course for learning TypeScript.

        3. **TypeScript Deep Dive**
           https://basarat.gitbook.io/typescript/
           Comprehensive guide to TypeScript.
        """
        let arguments = "{\"query\": \"TypeScript tutorial\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.results.count == 3)
        #expect(parsed.results[0].title == "TypeScript Documentation")
        #expect(parsed.results[0].url == "https://www.typescriptlang.org/docs/")
        #expect(parsed.results[1].title == "Learn TypeScript - FreeCodeCamp")
    }

    @Test("Extracts snippets from search results")
    func testExtractsSnippets() {
        let result = """
        Found 1 results:

        1. **Example Page**
           https://example.com
           This is the snippet text describing the page content.
        """
        let arguments = "{\"query\": \"example\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.results.count == 1)
        #expect(parsed.results[0].snippet.contains("snippet text describing"))
    }

    @Test("Extracts total results count")
    func testExtractsTotalResultsCount() {
        let result = """
        Found 25 results for 'Swift programming':

        1. **Swift.org**
           https://swift.org
           The Swift programming language.
        """
        let arguments = "{\"query\": \"Swift programming\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.totalResults == 25)
    }

    @Test("Handles JSON total results format")
    func testHandlesJsonTotalResults() {
        let result = "{\"totalResults\": 15, \"results\": []}"
        let arguments = "{\"query\": \"test\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.totalResults == 15)
    }

    // MARK: - Error Handling

    @Test("Parses error from Error: prefix")
    func testParsesErrorWithPrefix() {
        let result = "Error: Rate limit exceeded"
        let arguments = "{\"query\": \"test\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.error != nil)
        #expect(parsed.error?.contains("Rate limit") == true)
        #expect(parsed.results.isEmpty)
    }

    @Test("Parses error from JSON format")
    func testParsesErrorFromJson() {
        let result = "{\"error\": \"Invalid API key\"}"
        let arguments = "{\"query\": \"test\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.error != nil)
        #expect(parsed.error?.contains("Invalid API key") == true)
    }

    // MARK: - No Results Handling

    @Test("Handles no results response")
    func testHandlesNoResults() {
        let result = "Found 0 results for 'xyznonexistentquery123'"
        let arguments = "{\"query\": \"xyznonexistentquery123\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.results.isEmpty)
        #expect(parsed.totalResults == 0)
        #expect(parsed.error == nil)
    }

    @Test("Handles empty results array")
    func testHandlesEmptyResultsArray() {
        let result = "No results found."
        let arguments = "{\"query\": \"obscure query\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.results.isEmpty)
    }

    // MARK: - Edge Cases

    @Test("Handles missing query in arguments")
    func testHandlesMissingQuery() {
        let result = "Results..."
        let arguments = "{}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.query.isEmpty)
    }

    @Test("Handles empty result string")
    func testHandlesEmptyResult() {
        let result = ""
        let arguments = "{\"query\": \"test\"}"

        let parsed = WebSearchParsedResults(from: result, arguments: arguments)

        #expect(parsed.results.isEmpty)
        #expect(parsed.error == nil)
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
