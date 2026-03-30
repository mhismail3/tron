import SwiftUI

// MARK: - WebFetch Detail Parser

/// Parsing and error classification for WebFetch detail sheet.
enum WebFetchDetailParser {

    /// Extract just the error message from a result string.
    static func extractError(from result: String) -> String {
        if result.hasPrefix("Error:") {
            return String(result.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = result.firstMatch(of: /"error"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return result
    }

    /// Detect if the result indicates a cached response.
    static func isCached(_ result: String) -> Bool {
        result.contains("fromCache") && result.contains("true")
    }

    /// Classify an error message into a structured type with icon, title, code, suggestion.
    static func classifyError(_ message: String) -> ErrorClassification {
        let lower = message.lowercased()

        if lower.contains("404") || lower.contains("not found") {
            return ErrorClassification(icon: "questionmark.folder", title: "Page Not Found", code: "HTTP 404",
                    suggestion: "The page may have been moved or deleted. Check the URL.")
        }
        if lower.contains("403") || lower.contains("forbidden") {
            return ErrorClassification(icon: "lock.fill", title: "Access Forbidden", code: "HTTP 403",
                    suggestion: "The server denied access to this page.")
        }
        if lower.contains("401") || lower.contains("unauthorized") {
            return ErrorClassification(icon: "lock.shield", title: "Unauthorized", code: "HTTP 401",
                    suggestion: "Authentication is required to access this page.")
        }
        if lower.contains("429") || lower.contains("rate limit") {
            return ErrorClassification(icon: "clock.badge.exclamationmark", title: "Rate Limited", code: "HTTP 429",
                    suggestion: "Too many requests. Try again in a moment.")
        }
        if lower.contains("500") || lower.contains("internal server") {
            return ErrorClassification(icon: "server.rack", title: "Server Error", code: "HTTP 500",
                    suggestion: "The remote server encountered an error.")
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return ErrorClassification(icon: "clock.arrow.circlepath", title: "Request Timed Out", code: nil,
                    suggestion: "The page took too long to respond. Try again later.")
        }
        if lower.contains("dns") || lower.contains("resolve") || lower.contains("no such host") {
            return ErrorClassification(icon: "wifi.slash", title: "DNS Error", code: nil,
                    suggestion: "Could not resolve the domain. Check the URL is correct.")
        }
        if lower.contains("ssl") || lower.contains("certificate") || lower.contains("tls") {
            return ErrorClassification(icon: "lock.trianglebadge.exclamationmark", title: "SSL Error", code: nil,
                    suggestion: "There was a problem with the site's security certificate.")
        }
        if lower.contains("redirect") {
            return ErrorClassification(icon: "arrow.triangle.turn.up.right.diamond", title: "Redirect Detected", code: nil,
                    suggestion: "The page redirected to a different host. Try fetching the redirect URL.")
        }
        if lower.contains("blocked") || lower.contains("denied") {
            return ErrorClassification(icon: "shield.slash", title: "Domain Blocked", code: nil,
                    suggestion: "This domain is blocked from being fetched.")
        }

        return ErrorClassification(icon: "exclamationmark.triangle.fill", title: "Fetch Failed", code: nil,
                suggestion: "An error occurred while fetching the page.")
    }
}

// MARK: - WebFetchParsedResult Extensions

extension WebFetchParsedResult {
    /// Whether the result came from cache. Only applies to summarization mode.
    /// Uses text heuristic; for structured detection, use `isCachedFromDetails`.
    var isCached: Bool {
        guard !isRawMode else { return false }
        return WebFetchDetailParser.isCached(answer)
    }

    /// Check cache status from structured details (persisted in tool.result event).
    static func isCachedFromDetails(_ details: [String: AnyCodable]?) -> Bool {
        guard let details else { return false }
        return details["fromCache"]?.value as? Bool == true
    }
}
