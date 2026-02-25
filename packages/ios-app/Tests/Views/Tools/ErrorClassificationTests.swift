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

    @Test("WebSearch classifies API errors")
    func testWebSearchAPIErrors() {
        let rateLimit = WebSearchDetailParser.classifyError("Rate limit exceeded (429)")
        #expect(rateLimit.title == "Rate Limited")
        #expect(rateLimit.code == "429")

        let apiKey = WebSearchDetailParser.classifyError("Invalid API key")
        #expect(apiKey.title == "API Key Error")

        let quota = WebSearchDetailParser.classifyError("Quota exceeded")
        #expect(quota.title == "Quota Exceeded")
    }

    // MARK: - Remember Classifier

    @Test("Remember classifies database errors")
    func testRememberErrors() {
        let invalidAction = RememberDetailParser.classifyError("Invalid action: xyz")
        #expect(invalidAction.title == "Invalid Action")
        #expect(invalidAction.code == "INVALID_ACTION")

        let notFound = RememberDetailParser.classifyError("Session not found")
        #expect(notFound.title == "Not Found")
    }

    // MARK: - OpenURL Classifier

    @Test("OpenURL classifies URL errors")
    func testOpenURLErrors() {
        let invalidFormat = OpenURLDetailParser.classifyError("Invalid URL format: bad")
        #expect(invalidFormat.title == "Invalid URL")
        #expect(invalidFormat.code == "INVALID_FORMAT")

        let invalidScheme = OpenURLDetailParser.classifyError("Invalid URL scheme: ftp")
        #expect(invalidScheme.title == "Invalid Scheme")
    }
}
