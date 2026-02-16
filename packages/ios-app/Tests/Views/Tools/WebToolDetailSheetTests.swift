import Testing
import Foundation
@testable import TronMobile

// MARK: - WebFetchDetailParser Tests

@Suite("WebFetchDetailParser")
struct WebFetchDetailParserTests {

    // MARK: - Error Extraction

    @Test("Extracts error from 'Error:' prefix")
    func testExtractErrorPrefix() {
        let error = WebFetchDetailParser.extractError(from: "Error: HTTP 404 - Page not found")
        #expect(error == "HTTP 404 - Page not found")
    }

    @Test("Extracts error from JSON error field")
    func testExtractErrorJSON() {
        let error = WebFetchDetailParser.extractError(from: "{\"error\": \"Connection refused\"}")
        #expect(error == "Connection refused")
    }

    @Test("Returns raw string for unrecognized error format")
    func testExtractErrorFallback() {
        let msg = "Something went wrong"
        let error = WebFetchDetailParser.extractError(from: msg)
        #expect(error == msg)
    }

    // MARK: - Error Classification

    @Test("Classifies 404 error")
    func testClassify404() {
        let info = WebFetchDetailParser.classifyError("HTTP 404 - Page not found")
        #expect(info.title == "Page Not Found")
        #expect(info.code == "HTTP 404")
        #expect(info.icon == "questionmark.folder")
    }

    @Test("Classifies 403 error")
    func testClassify403() {
        let info = WebFetchDetailParser.classifyError("HTTP 403 Forbidden")
        #expect(info.title == "Access Forbidden")
        #expect(info.code == "HTTP 403")
    }

    @Test("Classifies 401 error")
    func testClassify401() {
        let info = WebFetchDetailParser.classifyError("Unauthorized access (401)")
        #expect(info.title == "Unauthorized")
        #expect(info.code == "HTTP 401")
    }

    @Test("Classifies rate limit error")
    func testClassifyRateLimit() {
        let info = WebFetchDetailParser.classifyError("Rate limit exceeded (429)")
        #expect(info.title == "Rate Limited")
        #expect(info.code == "HTTP 429")
    }

    @Test("Classifies 500 error")
    func testClassify500() {
        let info = WebFetchDetailParser.classifyError("Internal server error (500)")
        #expect(info.title == "Server Error")
        #expect(info.code == "HTTP 500")
    }

    @Test("Classifies timeout error")
    func testClassifyTimeout() {
        let info = WebFetchDetailParser.classifyError("Request timed out after 30 seconds")
        #expect(info.title == "Request Timed Out")
        #expect(info.code == nil)
    }

    @Test("Classifies DNS error")
    func testClassifyDNS() {
        let info = WebFetchDetailParser.classifyError("Could not resolve host: no such host")
        #expect(info.title == "DNS Error")
        #expect(info.code == nil)
    }

    @Test("Classifies SSL error")
    func testClassifySSL() {
        let info = WebFetchDetailParser.classifyError("SSL certificate verification failed")
        #expect(info.title == "SSL Error")
    }

    @Test("Classifies redirect error")
    func testClassifyRedirect() {
        let info = WebFetchDetailParser.classifyError("Page redirected to a different host")
        #expect(info.title == "Redirect Detected")
    }

    @Test("Classifies blocked domain error")
    func testClassifyBlocked() {
        let info = WebFetchDetailParser.classifyError("Domain blocked from fetching")
        #expect(info.title == "Domain Blocked")
    }

    @Test("Classifies generic error")
    func testClassifyGeneric() {
        let info = WebFetchDetailParser.classifyError("Something unexpected happened")
        #expect(info.title == "Fetch Failed")
        #expect(info.code == nil)
    }

    // MARK: - Cache Detection

    @Test("Detects cached response")
    func testIsCachedTrue() {
        #expect(WebFetchDetailParser.isCached("fromCache: true") == true)
    }

    @Test("Returns false for non-cached response")
    func testIsCachedFalse() {
        #expect(WebFetchDetailParser.isCached("Normal response content") == false)
    }
}

// MARK: - WebSearchDetailParser Tests

@Suite("WebSearchDetailParser")
struct WebSearchDetailParserTests {

    // MARK: - Error Extraction

    @Test("Extracts error from 'Error:' prefix")
    func testExtractErrorPrefix() {
        let error = WebSearchDetailParser.extractError(from: "Error: Rate limit exceeded")
        #expect(error == "Rate limit exceeded")
    }

    @Test("Extracts error from JSON error field")
    func testExtractErrorJSON() {
        let error = WebSearchDetailParser.extractError(from: "{\"error\": \"API key invalid\"}")
        #expect(error == "API key invalid")
    }

    @Test("Returns raw string for unrecognized format")
    func testExtractErrorFallback() {
        let msg = "Unknown error"
        let error = WebSearchDetailParser.extractError(from: msg)
        #expect(error == msg)
    }

    // MARK: - Error Classification

    @Test("Classifies rate limit error")
    func testClassifyRateLimit() {
        let info = WebSearchDetailParser.classifyError("Rate limit exceeded (429)")
        #expect(info.title == "Rate Limited")
        #expect(info.code == "429")
    }

    @Test("Classifies API key error")
    func testClassifyAPIKey() {
        let info = WebSearchDetailParser.classifyError("Invalid API key")
        #expect(info.title == "API Key Error")
        #expect(info.code == "401")
    }

    @Test("Classifies quota error")
    func testClassifyQuota() {
        let info = WebSearchDetailParser.classifyError("Monthly quota exceeded")
        #expect(info.title == "Quota Exceeded")
        #expect(info.code == nil)
    }

    @Test("Classifies timeout error")
    func testClassifyTimeout() {
        let info = WebSearchDetailParser.classifyError("Search request timed out")
        #expect(info.title == "Search Timed Out")
    }

    @Test("Classifies invalid query error")
    func testClassifyInvalidQuery() {
        let info = WebSearchDetailParser.classifyError("Invalid query parameter")
        #expect(info.title == "Invalid Query")
    }

    @Test("Classifies generic error")
    func testClassifyGeneric() {
        let info = WebSearchDetailParser.classifyError("Something went wrong")
        #expect(info.title == "Search Failed")
        #expect(info.code == nil)
    }
}

// MARK: - WebFetchParsedResult Tests

@Suite("WebFetch Parsing")
@MainActor
struct WebFetchParsingTests {

    @Test("Parses answer from simple result")
    func testSimpleAnswer() {
        let result = WebFetchParsedResult(from: "The answer is 42.", arguments: "{\"url\": \"https://example.com\"}")
        #expect(result.answer == "The answer is 42.")
        #expect(result.error == nil)
    }

    @Test("Extracts answer before Source: line")
    func testAnswerBeforeSource() {
        let result = WebFetchParsedResult(
            from: "Main content here.\n\nSource: https://example.com",
            arguments: "{\"url\": \"https://example.com\"}"
        )
        #expect(result.answer == "Main content here.")
    }

    @Test("Extracts answer before --- separator")
    func testAnswerBeforeSeparator() {
        let result = WebFetchParsedResult(
            from: "Content before separator.\n\n---\nUse WebFetch to read more.",
            arguments: "{\"url\": \"https://example.com\"}"
        )
        #expect(result.answer == "Content before separator.")
    }

    @Test("Parses error result")
    func testErrorResult() {
        let result = WebFetchParsedResult(
            from: "Error: HTTP 404 - Page not found",
            arguments: "{\"url\": \"https://example.com/missing\"}"
        )
        #expect(result.error != nil)
        #expect(result.answer.isEmpty)
    }

    @Test("Extracts source URL from arguments")
    func testSourceExtraction() {
        let result = WebFetchParsedResult(
            from: "Content here",
            arguments: "{\"url\": \"https://docs.anthropic.com/en/docs\"}"
        )
        #expect(result.source?.url == "https://docs.anthropic.com/en/docs")
        #expect(result.source?.domain == "docs.anthropic.com")
    }

    @Test("Extracts title from result")
    func testTitleExtraction() {
        let result = WebFetchParsedResult(
            from: "Content here\n\nTitle: My Page Title",
            arguments: "{\"url\": \"https://example.com\"}"
        )
        #expect(result.source?.title == "My Page Title")
    }

    @Test("Strips www. from domain")
    func testWWWStripping() {
        let result = WebFetchParsedResult(
            from: "Content",
            arguments: "{\"url\": \"https://www.example.com/page\"}"
        )
        #expect(result.source?.domain == "example.com")
    }

    @Test("Handles missing URL gracefully")
    func testMissingURL() {
        let result = WebFetchParsedResult(from: "Content", arguments: "{}")
        #expect(result.source == nil)
    }
}

// MARK: - WebSearchParsedResults Tests

@Suite("WebSearch Parsing")
@MainActor
struct WebSearchParsingTests {

    @Test("Extracts query from arguments")
    func testQueryExtraction() {
        let result = WebSearchParsedResults(from: "No results", arguments: "{\"query\": \"Swift async\"}")
        #expect(result.query == "Swift async")
    }

    @Test("Parses markdown-format search results")
    func testMarkdownResults() {
        let text = "Found 2 results:\n\n1. **First Result Title**\n   https://example.com/first\n   This is the first snippet.\n\n2. **Second Result Title**\n   https://example.com/second\n   This is the second snippet."
        let result = WebSearchParsedResults(from: text, arguments: "{\"query\": \"test\"}")
        #expect(result.results.count == 2)
        guard result.results.count >= 2 else { return }
        #expect(result.results[0].title == "First Result Title")
        #expect(result.results[0].url == "https://example.com/first")
        #expect(result.results[0].snippet.contains("first snippet"))
        #expect(result.results[1].title == "Second Result Title")
    }

    @Test("Extracts total results count")
    func testTotalResultsCount() {
        let text = "Found 15 results:\n\n1. **Title**\nhttps://example.com\nSnippet."
        let result = WebSearchParsedResults(from: text, arguments: "{\"query\": \"test\"}")
        #expect(result.totalResults == 15)
    }

    @Test("Detects error in results")
    func testErrorDetection() {
        let result = WebSearchParsedResults(
            from: "Error: Rate limit exceeded",
            arguments: "{\"query\": \"test\"}"
        )
        #expect(result.error != nil)
        #expect(result.results.isEmpty)
    }

    @Test("Returns empty results for no matches")
    func testNoMatches() {
        let result = WebSearchParsedResults(
            from: "Found 0 results for 'nonexistent'",
            arguments: "{\"query\": \"nonexistent\"}"
        )
        #expect(result.results.isEmpty)
    }

    @Test("Handles empty query gracefully")
    func testEmptyQuery() {
        let result = WebSearchParsedResults(from: "Results", arguments: "{}")
        #expect(result.query == "")
    }
}

// MARK: - SearchResult DisplayUrl Tests

@Suite("SearchResult DisplayUrl")
@MainActor
struct WebSearchResultUrlTests {

    @Test("Formats URL with domain and short path")
    func testShortPath() {
        let result = SearchResult(title: "Test", url: "https://example.com/page", snippet: "", age: nil)
        #expect(result.displayUrl.contains("example.com"))
    }

    @Test("Truncates long URL paths")
    func testLongPath() {
        let result = SearchResult(
            title: "Test",
            url: "https://example.com/very/long/path/that/exceeds/thirty/characters/total",
            snippet: "",
            age: nil
        )
        #expect(result.displayUrl.contains("..."))
    }

    @Test("Handles invalid URL gracefully")
    func testInvalidURL() {
        let result = SearchResult(title: "Test", url: "not-a-url", snippet: "", age: nil)
        #expect(result.displayUrl == "not-a-url")
    }
}
