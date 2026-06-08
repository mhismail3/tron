import Foundation
import Testing

@testable import TronMobile

@Suite("Network diagnostics formatter")
struct NetworkDiagnosticsFormatterTests {

    @Test("request summary records connection shape without bearer token")
    func requestSummaryRedactsBearerToken() {
        var request = URLRequest(url: URL(string: "ws://100.95.255.62:9847/engine?token=secret")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer very-secret-token", forHTTPHeaderField: "Authorization")

        let summary = NetworkDiagnosticsFormatter.requestSummary(request)

        #expect(summary.contains("method=GET"))
        #expect(summary.contains("url=ws://100.95.255.62:9847/engine"))
        #expect(summary.contains("timeout=10.0s"))
        #expect(summary.contains("authorization=present"))
        #expect(!summary.contains("very-secret-token"))
        #expect(!summary.contains("token=secret"))
    }

    @Test("error summary records NSError domain code and redacted URL")
    func errorSummaryIncludesUsefulNSErrorFields() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [
                NSLocalizedDescriptionKey: "The request timed out.",
                NSURLErrorFailingURLErrorKey: URL(string: "ws://host.example:9847/engine?token=secret")!,
                NSUnderlyingErrorKey: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: 60,
                    userInfo: [NSLocalizedDescriptionKey: "Operation timed out"]
                ),
            ]
        )

        let summary = NetworkDiagnosticsFormatter.errorSummary(error)

        #expect(summary.contains("domain=\(NSURLErrorDomain)"))
        #expect(summary.contains("code=\(NSURLErrorTimedOut)"))
        #expect(summary.contains("failingURL=ws://host.example:9847/engine"))
        #expect(summary.contains("underlying={domain=\(NSPOSIXErrorDomain) code=60"))
        #expect(!summary.contains("token=secret"))
    }

    @Test("response summary includes HTTP status and redacted URL")
    func responseSummaryIncludesHTTPStatus() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "http://100.95.255.62:9847/health?token=secret")!,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        ))

        let summary = NetworkDiagnosticsFormatter.responseSummary(response)

        #expect(summary.contains("status=401"))
        #expect(summary.contains("url=http://100.95.255.62:9847/health"))
        #expect(!summary.contains("token=secret"))
    }
}
