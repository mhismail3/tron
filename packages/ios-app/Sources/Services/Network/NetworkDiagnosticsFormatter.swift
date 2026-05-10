import Foundation

enum NetworkDiagnosticsFormatter {
    static func requestSummary(_ request: URLRequest) -> String {
        let url = request.url
        let method = request.httpMethod ?? "GET"
        let authState = request.value(forHTTPHeaderField: "Authorization") == nil ? "missing" : "present"
        return [
            "method=\(method)",
            "url=\(redactedURLSummary(url))",
            "timeout=\(formatSeconds(request.timeoutInterval))",
            "authorization=\(authState)",
        ].joined(separator: " ")
    }

    static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)",
            "description=\(nsError.localizedDescription)",
        ]

        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("failingURL=\(redactedURLSummary(failingURL))")
        }

        if let reason = nsError.userInfo[NSURLErrorNetworkUnavailableReasonKey] {
            parts.append("networkUnavailableReason=\(reason)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(
                "underlying={domain=\(underlying.domain) code=\(underlying.code) description=\(underlying.localizedDescription)}"
            )
        }

        return parts.joined(separator: " ")
    }

    static func responseSummary(_ response: URLResponse) -> String {
        if let http = response as? HTTPURLResponse {
            return [
                "status=\(http.statusCode)",
                "url=\(redactedURLSummary(http.url))",
                "mime=\(http.mimeType ?? "unknown")",
                "expectedBytes=\(http.expectedContentLength)",
            ].joined(separator: " ")
        }
        return [
            "url=\(redactedURLSummary(response.url))",
            "mime=\(response.mimeType ?? "unknown")",
            "expectedBytes=\(response.expectedContentLength)",
        ].joined(separator: " ")
    }

    static func metricsSummary(_ metrics: URLSessionTaskMetrics) -> String {
        let taskMs = formatMilliseconds(metrics.taskInterval.duration)
        let transactions = metrics.transactionMetrics.enumerated().map { index, transaction in
            transactionSummary(transaction, index: index)
        }.joined(separator: " | ")
        return "taskDuration=\(taskMs) redirects=\(metrics.redirectCount) transactions=[\(transactions)]"
    }

    static func redactedURLSummary(_ url: URL?) -> String {
        guard let url else { return "unknown" }
        let scheme = url.scheme ?? "unknown"
        let host = url.host ?? "unknown"
        let port: String
        if let explicitPort = url.port {
            port = ":\(explicitPort)"
        } else {
            port = ""
        }
        let path = url.path.isEmpty ? "/" : url.path
        return "\(scheme)://\(host)\(port)\(path)"
    }

    private static func transactionSummary(
        _ transaction: URLSessionTaskTransactionMetrics,
        index: Int
    ) -> String {
        let protocolName = transaction.networkProtocolName ?? "unknown"
        let responseStatus: String
        if let http = transaction.response as? HTTPURLResponse {
            responseStatus = "\(http.statusCode)"
        } else if transaction.response != nil {
            responseStatus = "non-http"
        } else {
            responseStatus = "none"
        }

        return [
            "#\(index)",
            "url=\(redactedURLSummary(transaction.request.url))",
            "fetch=\(String(describing: transaction.resourceFetchType))",
            "protocol=\(protocolName)",
            "proxy=\(transaction.isProxyConnection)",
            "reused=\(transaction.isReusedConnection)",
            "response=\(responseStatus)",
            "dns=\(duration(transaction.domainLookupStartDate, transaction.domainLookupEndDate))",
            "connect=\(duration(transaction.connectStartDate, transaction.connectEndDate))",
            "tls=\(duration(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate))",
            "request=\(duration(transaction.requestStartDate, transaction.requestEndDate))",
            "ttfb=\(duration(transaction.requestEndDate, transaction.responseStartDate))",
            "response=\(duration(transaction.responseStartDate, transaction.responseEndDate))",
        ].joined(separator: " ")
    }

    private static func duration(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "n/a" }
        return formatMilliseconds(end.timeIntervalSince(start))
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }

    private static func formatMilliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.0fms", seconds * 1000)
    }
}
