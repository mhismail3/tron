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

    @Test("Bash classifies exit code error")
    func testBashExitCode() {
        let c = BashErrorClassifier.classify("Command failed with exit code 1")
        #expect(c.title == "Command Failed")
        #expect(c.code == "EXIT 1")
    }

    @Test("Bash classifies timeout")
    func testBashTimeout() {
        let c = BashErrorClassifier.classify("Command timed out after 120s")
        #expect(c.title == "Command Timed Out")
        #expect(c.code == nil)
    }

    @Test("Bash classifies permission denied")
    func testBashPermissionDenied() {
        let c = BashErrorClassifier.classify("Permission denied: /usr/sbin/something")
        #expect(c.title == "Permission Denied")
        #expect(c.code == "EACCES")
    }

    @Test("Bash returns fallback for unknown")
    func testBashFallback() {
        let c = BashErrorClassifier.classify("something went wrong")
        #expect(c.title == "Command Failed")
    }
}
