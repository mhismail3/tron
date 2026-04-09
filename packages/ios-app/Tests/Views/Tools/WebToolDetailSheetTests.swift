import Testing
import Foundation
@testable import TronMobile

// MARK: - WebFetchDetailParser Tests

@Suite("WebFetchDetailParser")
struct WebFetchDetailParserTests {

    private func details(
        errorClass: String? = nil,
        error: String? = nil,
        httpStatus: Int? = nil,
        fromCache: Bool? = nil
    ) -> [String: AnyCodable] {
        var d: [String: AnyCodable] = [:]
        if let errorClass { d["errorClass"] = AnyCodable(errorClass) }
        if let error { d["error"] = AnyCodable(error) }
        if let httpStatus { d["httpStatus"] = AnyCodable(httpStatus) }
        if let fromCache { d["fromCache"] = AnyCodable(fromCache) }
        return d
    }

    @Test("Reads server-provided error message")
    func testErrorMessage() {
        #expect(
            WebFetchDetailParser.errorMessage(from: details(error: "HTTP 404 for https://x"))
                == "HTTP 404 for https://x"
        )
    }

    @Test("Returns nil when no error present")
    func testNoError() {
        #expect(WebFetchDetailParser.errorMessage(from: [:]) == nil)
        #expect(WebFetchDetailParser.errorMessage(from: nil) == nil)
    }

    @Test("Classifies not_found with HTTP code label")
    func testClassifyNotFound() {
        let info = WebFetchDetailParser.classify(
            details: details(errorClass: "not_found", httpStatus: 404)
        )
        #expect(info?.title == "Page Not Found")
        #expect(info?.code == "HTTP 404")
        #expect(info?.icon == "questionmark.folder")
    }

    @Test("Classifies forbidden, unauthorized, rate_limited, server_error")
    func testClassifyHttpCategories() {
        let forbidden = WebFetchDetailParser.classify(
            details: details(errorClass: "forbidden", httpStatus: 403))
        #expect(forbidden?.title == "Access Forbidden")
        #expect(forbidden?.code == "HTTP 403")

        let unauth = WebFetchDetailParser.classify(
            details: details(errorClass: "unauthorized", httpStatus: 401))
        #expect(unauth?.title == "Unauthorized")

        let rate = WebFetchDetailParser.classify(
            details: details(errorClass: "rate_limited", httpStatus: 429))
        #expect(rate?.title == "Rate Limited")

        let server = WebFetchDetailParser.classify(
            details: details(errorClass: "server_error", httpStatus: 503))
        #expect(server?.title == "Server Error")
        #expect(server?.code == "HTTP 503")
    }

    @Test("Classifies network-level errors without httpStatus")
    func testClassifyNetworkLevel() {
        for (cls, expected) in [
            ("timeout", "Request Timed Out"),
            ("dns", "DNS Error"),
            ("ssl", "SSL Error"),
            ("redirect", "Redirect Detected"),
            ("blocked", "Domain Blocked"),
            ("too_large", "Response Too Large"),
            ("invalid_url", "Invalid URL"),
            ("network", "Network Error"),
        ] {
            let info = WebFetchDetailParser.classify(details: details(errorClass: cls))
            #expect(info?.title == expected)
            #expect(info?.code == nil)
        }
    }

    @Test("Falls back to Fetch Failed for unknown errorClass")
    func testClassifyUnknown() {
        let info = WebFetchDetailParser.classify(details: details(errorClass: "weird"))
        #expect(info?.title == "Fetch Failed")
    }

    @Test("Returns nil when no errorClass present")
    func testClassifyNoClass() {
        #expect(WebFetchDetailParser.classify(details: [:]) == nil)
        #expect(WebFetchDetailParser.classify(details: nil) == nil)
    }

    @Test("isCached reads structured fromCache flag")
    func testIsCached() {
        #expect(WebFetchDetailParser.isCached(details: details(fromCache: true)))
        #expect(!WebFetchDetailParser.isCached(details: details(fromCache: false)))
        #expect(!WebFetchDetailParser.isCached(details: [:]))
        #expect(!WebFetchDetailParser.isCached(details: nil))
    }
}

// MARK: - WebFetchParsedResult Tests

@Suite("WebFetch Parsing")
@MainActor
struct WebFetchParsingTests {

    @Test("Parses summarization answer from details")
    func testSummarizationAnswer() {
        let d: [String: AnyCodable] = [
            "mode": AnyCodable("summarization"),
            "answer": AnyCodable("The answer is 42."),
            "fromCache": AnyCodable(false),
        ]
        let r = WebFetchParsedResult(details: d, arguments: "{\"url\": \"https://example.com\"}")
        #expect(r.displayContent == "The answer is 42.")
        #expect(r.error == nil)
        #expect(!r.isRawMode)
        #expect(!r.isCached)
    }

    @Test("Parses raw mode body from details")
    func testRawBody() {
        let d: [String: AnyCodable] = [
            "mode": AnyCodable("raw"),
            "method": AnyCodable("POST"),
            "httpStatus": AnyCodable(201),
            "body": AnyCodable("{\"ok\": true}"),
        ]
        let r = WebFetchParsedResult(
            details: d,
            arguments: "{\"url\": \"https://api.example.com/x\", \"method\": \"POST\"}"
        )
        #expect(r.isRawMode)
        #expect(r.httpMethod == "POST")
        #expect(r.httpStatus == 201)
        #expect(r.displayContent == "{\"ok\": true}")
    }

    @Test("Parses error from details — no displayContent")
    func testErrorResult() {
        let d: [String: AnyCodable] = [
            "error": AnyCodable("HTTP 404 for https://example.com/missing"),
            "errorClass": AnyCodable("not_found"),
            "httpStatus": AnyCodable(404),
        ]
        let r = WebFetchParsedResult(
            details: d,
            arguments: "{\"url\": \"https://example.com/missing\", \"prompt\": \"Read\"}"
        )
        #expect(r.error?.contains("404") == true)
        #expect(r.displayContent.isEmpty)
    }

    @Test("Extracts source URL and domain from arguments")
    func testSourceExtraction() {
        let r = WebFetchParsedResult(
            details: nil,
            arguments: "{\"url\": \"https://docs.anthropic.com/en/docs\"}"
        )
        #expect(r.source?.url == "https://docs.anthropic.com/en/docs")
        #expect(r.source?.domain == "docs.anthropic.com")
    }

    @Test("Reads title from details")
    func testTitleFromDetails() {
        let d: [String: AnyCodable] = [
            "mode": AnyCodable("summarization"),
            "title": AnyCodable("My Page Title"),
            "answer": AnyCodable("content"),
        ]
        let r = WebFetchParsedResult(
            details: d,
            arguments: "{\"url\": \"https://example.com\"}"
        )
        #expect(r.source?.title == "My Page Title")
    }

    @Test("Strips www. from domain")
    func testWWWStripping() {
        let r = WebFetchParsedResult(
            details: nil,
            arguments: "{\"url\": \"https://www.example.com/page\"}"
        )
        #expect(r.source?.domain == "example.com")
    }

    @Test("Handles missing URL gracefully")
    func testMissingURL() {
        let r = WebFetchParsedResult(details: nil, arguments: "{}")
        #expect(r.source == nil)
    }

    @Test("Extracts subagent session id from metadata")
    func testSubagentSessionIdMetadata() {
        let d: [String: AnyCodable] = [
            "mode": AnyCodable("summarization"),
            "answer": AnyCodable("x"),
            "subagentSessionId": AnyCodable("sub-sess-abc123"),
        ]
        let r = WebFetchParsedResult(
            details: d,
            arguments: "{\"url\": \"https://example.com\"}"
        )
        #expect(r.metadata?.subagentSessionId == "sub-sess-abc123")
    }

    @Test("Empty subagent session id yields nil metadata")
    func testEmptySubagentSessionId() {
        let d: [String: AnyCodable] = [
            "mode": AnyCodable("summarization"),
            "answer": AnyCodable("x"),
            "subagentSessionId": AnyCodable(""),
        ]
        let r = WebFetchParsedResult(
            details: d,
            arguments: "{\"url\": \"https://example.com\"}"
        )
        #expect(r.metadata == nil)
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
