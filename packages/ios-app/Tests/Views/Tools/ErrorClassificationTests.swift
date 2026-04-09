import Testing
import Foundation
@testable import TronMobile

// MARK: - ErrorClassification Tests

@Suite("ErrorClassification")
struct ErrorClassificationTests {

    @Test("Struct stores all fields correctly")
    func testAllFields() {
        let classification = ErrorClassification(
            icon: "lock.fill",
            title: "Forbidden",
            code: "HTTP 403",
            suggestion: "Check your credentials."
        )
        #expect(classification.icon == "lock.fill")
        #expect(classification.title == "Forbidden")
        #expect(classification.code == "HTTP 403")
        #expect(classification.suggestion == "Check your credentials.")
    }

    @Test("Struct supports nil code")
    func testNilCode() {
        let classification = ErrorClassification(
            icon: "exclamationmark.triangle",
            title: "Unknown Error",
            code: nil,
            suggestion: "Try again."
        )
        #expect(classification.code == nil)
    }

    // MARK: - WebFetch Classifier

    private func webFetchDetails(errorClass: String?, httpStatus: Int? = nil) -> [String: AnyCodable]? {
        guard errorClass != nil || httpStatus != nil else { return nil }
        var d: [String: AnyCodable] = [:]
        if let errorClass { d["errorClass"] = AnyCodable(errorClass) }
        if let httpStatus { d["httpStatus"] = AnyCodable(httpStatus) }
        return d
    }

    @Test("WebFetch classifies HTTP errors from structured details")
    func testWebFetchHTTPErrors() {
        let c404 = WebFetchDetailParser.classify(details: webFetchDetails(errorClass: "not_found", httpStatus: 404))
        #expect(c404?.title == "Page Not Found")
        #expect(c404?.code == "HTTP 404")

        let c403 = WebFetchDetailParser.classify(details: webFetchDetails(errorClass: "forbidden", httpStatus: 403))
        #expect(c403?.title == "Access Forbidden")

        let cTimeout = WebFetchDetailParser.classify(details: webFetchDetails(errorClass: "timeout"))
        #expect(cTimeout?.title == "Request Timed Out")
        #expect(cTimeout?.code == nil)
    }

    @Test("WebFetch classifies network errors from structured details")
    func testWebFetchNetworkErrors() {
        let dns = WebFetchDetailParser.classify(details: webFetchDetails(errorClass: "dns"))
        #expect(dns?.title == "DNS Error")

        let ssl = WebFetchDetailParser.classify(details: webFetchDetails(errorClass: "ssl"))
        #expect(ssl?.title == "SSL Error")

        let blocked = WebFetchDetailParser.classify(details: webFetchDetails(errorClass: "blocked"))
        #expect(blocked?.title == "Domain Blocked")
    }

    @Test("WebFetch returns fallback for unknown errorClass")
    func testWebFetchFallback() {
        let unknown = WebFetchDetailParser.classify(details: webFetchDetails(errorClass: "weird"))
        #expect(unknown?.title == "Fetch Failed")
    }

    @Test("WebFetch returns nil when details have no errorClass")
    func testWebFetchNoErrorClass() {
        #expect(WebFetchDetailParser.classify(details: [:]) == nil)
        #expect(WebFetchDetailParser.classify(details: nil) == nil)
    }

    // MARK: - WebSearch Classifier

    private func webSearchDetails(errorClass: String?) -> [String: AnyCodable]? {
        guard let errorClass else { return nil }
        return ["errorClass": AnyCodable(errorClass)]
    }

    @Test("WebSearch classifies rate_limited")
    func testWebSearchRateLimited() {
        let c = WebSearchDetailParser.classify(details: webSearchDetails(errorClass: "rate_limited"))
        #expect(c.title == "Rate Limited")
        #expect(c.code == "429")
    }

    @Test("WebSearch classifies api_key")
    func testWebSearchApiKey() {
        let c = WebSearchDetailParser.classify(details: webSearchDetails(errorClass: "api_key"))
        #expect(c.title == "API Key Error")
    }

    @Test("WebSearch classifies quota")
    func testWebSearchQuota() {
        let c = WebSearchDetailParser.classify(details: webSearchDetails(errorClass: "quota"))
        #expect(c.title == "Quota Exceeded")
    }

    @Test("WebSearch classifies timeout")
    func testWebSearchTimeout() {
        let c = WebSearchDetailParser.classify(details: webSearchDetails(errorClass: "timeout"))
        #expect(c.title == "Search Timed Out")
    }

    @Test("WebSearch classifies invalid_query")
    func testWebSearchInvalidQuery() {
        let c = WebSearchDetailParser.classify(details: webSearchDetails(errorClass: "invalid_query"))
        #expect(c.title == "Invalid Query")
    }

    @Test("WebSearch classifies network")
    func testWebSearchNetwork() {
        let c = WebSearchDetailParser.classify(details: webSearchDetails(errorClass: "network"))
        #expect(c.title == "Network Error")
    }

    @Test("WebSearch falls back for unknown errorClass")
    func testWebSearchUnknown() {
        let c = WebSearchDetailParser.classify(details: webSearchDetails(errorClass: "unknown"))
        #expect(c.title == "Search Failed")
    }

    @Test("WebSearch falls back when details missing")
    func testWebSearchMissingDetails() {
        let c = WebSearchDetailParser.classify(details: nil)
        #expect(c.title == "Search Failed")
    }

    @Test("WebSearch reads errorMessage from details")
    func testWebSearchErrorMessage() {
        let details: [String: AnyCodable] = ["error": AnyCodable("Brave API error: HTTP 429")]
        let msg = WebSearchDetailParser.errorMessage(from: details)
        #expect(msg == "Brave API error: HTTP 429")
    }

    // MARK: - Search Classifier

    private func searchDetails(errorClass: String?, error: String? = nil) -> [String: AnyCodable]? {
        var d: [String: AnyCodable] = [:]
        if let errorClass { d["errorClass"] = AnyCodable(errorClass) }
        if let error { d["error"] = AnyCodable(error) }
        return d.isEmpty ? nil : d
    }

    @Test("Search classifies invalid_pattern from structured details")
    func testSearchInvalidRegex() {
        let c = SearchErrorClassifier.classify(details: searchDetails(errorClass: "invalid_pattern"))
        #expect(c.title == "Invalid Pattern")
        #expect(c.code == nil)
    }

    @Test("Search returns fallback for other errorClass")
    func testSearchFallback() {
        let c = SearchErrorClassifier.classify(details: searchDetails(errorClass: "other"))
        #expect(c.title == "Search Failed")
    }

    @Test("Search returns fallback when details nil")
    func testSearchNilDetails() {
        let c = SearchErrorClassifier.classify(details: nil)
        #expect(c.title == "Search Failed")
    }

    @Test("Search reads errorMessage from details")
    func testSearchErrorMessage() {
        let msg = SearchErrorClassifier.errorMessage(
            from: searchDetails(errorClass: "invalid_pattern", error: "Invalid regex: [unterminated"))
        #expect(msg == "Invalid regex: [unterminated")
    }

    // MARK: - Glob Classifier

    private func globDetails(errorClass: String?, error: String? = nil) -> [String: AnyCodable]? {
        var d: [String: AnyCodable] = [:]
        if let errorClass { d["errorClass"] = AnyCodable(errorClass) }
        if let error { d["error"] = AnyCodable(error) }
        return d.isEmpty ? nil : d
    }

    @Test("Glob classifies invalid_pattern from structured details")
    func testGlobInvalidPattern() {
        let c = GlobErrorClassifier.classify(details: globDetails(errorClass: "invalid_pattern"))
        #expect(c.title == "Invalid Glob Pattern")
    }

    @Test("Glob returns fallback for other errorClass")
    func testGlobFallback() {
        let c = GlobErrorClassifier.classify(details: globDetails(errorClass: "other"))
        #expect(c.title == "Find Failed")
    }

    @Test("Glob returns fallback when details nil")
    func testGlobNilDetails() {
        let c = GlobErrorClassifier.classify(details: nil)
        #expect(c.title == "Find Failed")
    }

    @Test("Glob reads errorMessage from details")
    func testGlobErrorMessage() {
        let msg = GlobErrorClassifier.errorMessage(
            from: globDetails(errorClass: "invalid_pattern", error: "Invalid glob pattern: [bad"))
        #expect(msg == "Invalid glob pattern: [bad")
    }

    // MARK: - Bash Classifier

    /// Helper: build a details dict for the bash classifier.
    private func bashDetails(exitCode: Int? = nil, errorClass: String? = nil) -> [String: AnyCodable] {
        var d: [String: AnyCodable] = [:]
        if let code = exitCode { d["exitCode"] = AnyCodable(code) }
        if let cls = errorClass { d["errorClass"] = AnyCodable(cls) }
        return d
    }

    @Test("Bash classifies exit code from structured details")
    func testBashExitCode() {
        let c = BashErrorClassifier.classify(details: bashDetails(exitCode: 1))
        #expect(c.title == "Command Failed")
        #expect(c.code == "EXIT 1")
    }

    @Test("Bash classifies multi-digit exit codes")
    func testBashMultiDigitExitCode() {
        let c = BashErrorClassifier.classify(details: bashDetails(exitCode: 130))
        #expect(c.code == "EXIT 130")
    }

    @Test("Bash classifies timeout from server errorClass")
    func testBashTimeout() {
        let c = BashErrorClassifier.classify(details: bashDetails(errorClass: "timeout"))
        #expect(c.title == "Command Timed Out")
        #expect(c.code == nil)
    }

    @Test("Bash classifies permission denied from server errorClass")
    func testBashPermissionDenied() {
        let c = BashErrorClassifier.classify(details: bashDetails(errorClass: "permission_denied"))
        #expect(c.title == "Permission Denied")
        #expect(c.code == "EACCES")
    }

    @Test("Bash classifies blocked command from server errorClass")
    func testBashBlocked() {
        let c = BashErrorClassifier.classify(details: bashDetails(errorClass: "blocked"))
        #expect(c.title == "Command Blocked")
    }

    @Test("Bash classifies interrupted from server errorClass")
    func testBashInterrupted() {
        let c = BashErrorClassifier.classify(details: bashDetails(errorClass: "interrupted"))
        #expect(c.title == "Interrupted")
    }

    @Test("Bash returns fallback for missing details")
    func testBashMissingDetails() {
        let c = BashErrorClassifier.classify(details: nil)
        #expect(c.title == "Command Failed")
        #expect(c.code == nil)
    }

    @Test("Bash returns exit code fallback when errorClass missing")
    func testBashExitCodeFallback() {
        let c = BashErrorClassifier.classify(details: bashDetails(exitCode: 2))
        #expect(c.title == "Command Failed")
        #expect(c.code == "EXIT 2")
    }

    @Test("Bash errorClass wins over exit code")
    func testBashErrorClassPrecedence() {
        // Even if exitCode is present, a structured errorClass takes precedence.
        let c = BashErrorClassifier.classify(details: bashDetails(exitCode: 124, errorClass: "timeout"))
        #expect(c.title == "Command Timed Out")
    }
}
