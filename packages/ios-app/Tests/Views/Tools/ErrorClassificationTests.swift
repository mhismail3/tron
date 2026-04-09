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

    @Test("WebFetch classifies HTTP errors")
    func testWebFetchHTTPErrors() {
        let c404 = WebFetchDetailParser.classifyError("HTTP 404 not found")
        #expect(c404.title == "Page Not Found")
        #expect(c404.code == "HTTP 404")

        let c403 = WebFetchDetailParser.classifyError("403 Forbidden")
        #expect(c403.title == "Access Forbidden")

        let cTimeout = WebFetchDetailParser.classifyError("Request timed out")
        #expect(cTimeout.title == "Request Timed Out")
        #expect(cTimeout.code == nil)
    }

    @Test("WebFetch classifies network errors")
    func testWebFetchNetworkErrors() {
        let dns = WebFetchDetailParser.classifyError("Could not resolve host")
        #expect(dns.title == "DNS Error")

        let ssl = WebFetchDetailParser.classifyError("SSL certificate error")
        #expect(ssl.title == "SSL Error")

        let blocked = WebFetchDetailParser.classifyError("Domain blocked")
        #expect(blocked.title == "Domain Blocked")
    }

    @Test("WebFetch returns fallback for unknown errors")
    func testWebFetchFallback() {
        let unknown = WebFetchDetailParser.classifyError("something weird happened")
        #expect(unknown.title == "Fetch Failed")
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

    @Test("Search classifies invalid regex")
    func testSearchInvalidRegex() {
        let c = SearchErrorClassifier.classify("Invalid regex pattern: [invalid - unterminated character class")
        #expect(c.title == "Invalid Pattern")
        #expect(c.code == nil)
    }

    @Test("Search classifies permission denied")
    func testSearchPermissionDenied() {
        let c = SearchErrorClassifier.classify("Permission denied: /root/secret")
        #expect(c.title == "Permission Denied")
        #expect(c.code == "EACCES")
    }

    @Test("Search classifies path not found")
    func testSearchPathNotFound() {
        let c = SearchErrorClassifier.classify("No such file or directory: /missing/path")
        #expect(c.title == "Path Not Found")
        #expect(c.code == "ENOENT")
    }

    @Test("Search returns fallback for unknown")
    func testSearchFallback() {
        let c = SearchErrorClassifier.classify("something weird happened")
        #expect(c.title == "Search Failed")
    }

    // MARK: - Glob Classifier

    @Test("Glob classifies permission denied")
    func testGlobPermissionDenied() {
        let c = GlobErrorClassifier.classify("EACCES: Permission denied")
        #expect(c.title == "Permission Denied")
        #expect(c.code == "EACCES")
    }

    @Test("Glob classifies path not found")
    func testGlobPathNotFound() {
        let c = GlobErrorClassifier.classify("ENOENT: No such file or directory")
        #expect(c.title == "Path Not Found")
        #expect(c.code == "ENOENT")
    }

    @Test("Glob returns fallback for unknown")
    func testGlobFallback() {
        let c = GlobErrorClassifier.classify("unexpected glob error")
        #expect(c.title == "Search Failed")
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
