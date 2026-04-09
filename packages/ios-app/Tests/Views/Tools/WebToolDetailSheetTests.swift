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

// MARK: - WebFetch Raw Mode Detail Tests

@Suite("WebFetch Raw Mode Details")
struct WebFetchRawModeDetailTests {

    @Test("isCached returns false for raw mode responses")
    func testNotCachedInRawMode() {
        // Even if the text contains "fromCache" and "true", raw mode is never cached
        let parsed = WebFetchParsedResult(
            from: "HTTP 200 https://example.com\n\nfromCache: true\nthe content is true",
            arguments: "{\"url\": \"https://example.com\", \"rawResponse\": true}"
        )
        #expect(!parsed.isCached)
    }

    @Test("Error classification not applied in raw mode for non-2xx")
    func testNoErrorClassificationInRawMode() {
        // In raw mode, a 404 is not an error — it's just data
        let parsed = WebFetchParsedResult(
            from: "HTTP 404 https://api.example.com/missing\n\n{\"error\": \"not_found\"}",
            arguments: "{\"url\": \"https://api.example.com/missing\", \"rawResponse\": true}"
        )
        // error should be nil because raw mode doesn't classify HTTP errors
        #expect(parsed.error == nil)
        #expect(parsed.isRawMode)
    }

    @Test("Summarization mode still classifies errors")
    func testSummarizationModeStillClassifiesErrors() {
        let parsed = WebFetchParsedResult(
            from: "Error: HTTP 404 - Page not found",
            arguments: "{\"url\": \"https://example.com/bad\", \"prompt\": \"Read\"}"
        )
        #expect(!parsed.isRawMode)
        #expect(parsed.error != nil)
        #expect(parsed.error?.contains("404") == true)
    }
}

// MARK: - WebSearchDetailParser Tests

@Suite("WebSearchDetailParser")
struct WebSearchDetailParserTests {

    private func details(errorClass: String? = nil, error: String? = nil) -> [String: AnyCodable] {
        var d: [String: AnyCodable] = [:]
        if let errorClass { d["errorClass"] = AnyCodable(errorClass) }
        if let error { d["error"] = AnyCodable(error) }
        return d
    }

    @Test("Reads server-provided error message from details")
    func testErrorMessageFromDetails() {
        let msg = WebSearchDetailParser.errorMessage(from: details(error: "HTTP 429"))
        #expect(msg == "HTTP 429")
    }

    @Test("Classifies rate_limited from server errorClass")
    func testClassifyRateLimit() {
        let info = WebSearchDetailParser.classify(details: details(errorClass: "rate_limited"))
        #expect(info.title == "Rate Limited")
        #expect(info.code == "429")
    }

    @Test("Classifies api_key from server errorClass")
    func testClassifyAPIKey() {
        let info = WebSearchDetailParser.classify(details: details(errorClass: "api_key"))
        #expect(info.title == "API Key Error")
        #expect(info.code == "401")
    }

    @Test("Classifies quota from server errorClass")
    func testClassifyQuota() {
        let info = WebSearchDetailParser.classify(details: details(errorClass: "quota"))
        #expect(info.title == "Quota Exceeded")
        #expect(info.code == nil)
    }

    @Test("Classifies timeout from server errorClass")
    func testClassifyTimeout() {
        let info = WebSearchDetailParser.classify(details: details(errorClass: "timeout"))
        #expect(info.title == "Search Timed Out")
    }

    @Test("Classifies invalid_query from server errorClass")
    func testClassifyInvalidQuery() {
        let info = WebSearchDetailParser.classify(details: details(errorClass: "invalid_query"))
        #expect(info.title == "Invalid Query")
    }

    @Test("Falls back to Search Failed for unknown errorClass")
    func testClassifyGeneric() {
        let info = WebSearchDetailParser.classify(details: details(errorClass: "unknown"))
        #expect(info.title == "Search Failed")
        #expect(info.code == nil)
    }

    @Test("Falls back when details nil")
    func testNilDetails() {
        let info = WebSearchDetailParser.classify(details: nil)
        #expect(info.title == "Search Failed")
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
            arguments: "{\"url\": \"https://example.com\", \"prompt\": \"Read\"}"
        )
        #expect(result.answer == "Main content here.")
    }

    @Test("Extracts answer before --- separator")
    func testAnswerBeforeSeparator() {
        let result = WebFetchParsedResult(
            from: "Content before separator.\n\n---\nUse WebFetch to read more.",
            arguments: "{\"url\": \"https://example.com\", \"prompt\": \"Read\"}"
        )
        #expect(result.answer == "Content before separator.")
    }

    @Test("Parses error result")
    func testErrorResult() {
        let result = WebFetchParsedResult(
            from: "Error: HTTP 404 - Page not found",
            arguments: "{\"url\": \"https://example.com/missing\", \"prompt\": \"Read\"}"
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

    private func details(results: [[String: Any]] = [], error: String? = nil, resultCount: Int? = nil) -> [String: AnyCodable] {
        var d: [String: AnyCodable] = [:]
        d["results"] = AnyCodable(results)
        if let error { d["error"] = AnyCodable(error) }
        if let resultCount { d["resultCount"] = AnyCodable(resultCount) }
        return d
    }

    @Test("Extracts query from arguments")
    func testQueryExtraction() {
        let result = WebSearchParsedResults(details: details(), arguments: "{\"query\": \"Swift async\"}")
        #expect(result.query == "Swift async")
    }

    @Test("Decodes results from structured details")
    func testDecodesResults() {
        let results: [[String: Any]] = [
            ["title": "First", "url": "https://example.com/first", "snippet": "first snippet"],
            ["title": "Second", "url": "https://example.com/second", "snippet": "second snippet"],
        ]
        let result = WebSearchParsedResults(
            details: details(results: results),
            arguments: "{\"query\": \"test\"}"
        )
        #expect(result.results.count == 2)
        #expect(result.results[0].title == "First")
        #expect(result.results[0].url == "https://example.com/first")
        #expect(result.results[0].snippet == "first snippet")
        #expect(result.results[1].title == "Second")
    }

    @Test("Uses resultCount from details for totalResults")
    func testTotalResultsFromDetails() {
        let result = WebSearchParsedResults(
            details: details(results: [["title": "t", "url": "u", "snippet": "s"]], resultCount: 15),
            arguments: "{\"query\": \"test\"}"
        )
        #expect(result.totalResults == 15)
    }

    @Test("Reads server-provided error message")
    func testErrorFromDetails() {
        let result = WebSearchParsedResults(
            details: details(error: "Rate limit exceeded"),
            arguments: "{\"query\": \"test\"}"
        )
        #expect(result.error == "Rate limit exceeded")
        #expect(result.results.isEmpty)
    }

    @Test("Returns empty results for empty array")
    func testEmptyResults() {
        let result = WebSearchParsedResults(
            details: details(results: [], resultCount: 0),
            arguments: "{\"query\": \"nonexistent\"}"
        )
        #expect(result.results.isEmpty)
    }

    @Test("Handles empty query gracefully")
    func testEmptyQuery() {
        let result = WebSearchParsedResults(details: details(), arguments: "{}")
        #expect(result.query == "")
    }

    @Test("Handles nil details")
    func testNilDetails() {
        let result = WebSearchParsedResults(details: nil, arguments: "{\"query\": \"test\"}")
        #expect(result.results.isEmpty)
        #expect(result.error == nil)
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
