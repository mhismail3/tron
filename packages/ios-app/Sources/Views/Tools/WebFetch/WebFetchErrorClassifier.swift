import SwiftUI

// MARK: - WebFetch Detail Parser

/// Reads structured error fields from WebFetch `tool.details`.
///
/// The server (`packages/agent/src/tools/web/web_fetch.rs`) classifies
/// every failure into an `errorClass` string and populates `details.error`,
/// `details.errorClass`, `details.httpStatus`. iOS does not scan text.
enum WebFetchDetailParser {

    /// Error message pulled straight from `details.error`. Returns `nil`
    /// when the tool did not emit one.
    static func errorMessage(from details: [String: AnyCodable]?) -> String? {
        details?["error"]?.value as? String
    }

    /// Structured classification built from `details.errorClass` +
    /// `details.httpStatus`. Returns `nil` when no error is present.
    static func classify(details: [String: AnyCodable]?) -> ErrorClassification? {
        guard let cls = details?["errorClass"]?.value as? String else { return nil }
        let statusInt: Int? = {
            if let i = details?["httpStatus"]?.value as? Int { return i }
            if let d = details?["httpStatus"]?.value as? Double { return Int(d) }
            return nil
        }()
        let codeLabel = statusInt.map { "HTTP \($0)" }
        switch cls {
        case "not_found":
            return ErrorClassification(
                icon: "questionmark.folder", title: "Page Not Found",
                code: codeLabel ?? "HTTP 404",
                suggestion: "The page may have been moved or deleted. Check the URL.")
        case "forbidden":
            return ErrorClassification(
                icon: "lock.fill", title: "Access Forbidden",
                code: codeLabel ?? "HTTP 403",
                suggestion: "The server denied access to this page.")
        case "unauthorized":
            return ErrorClassification(
                icon: "lock.shield", title: "Unauthorized",
                code: codeLabel ?? "HTTP 401",
                suggestion: "Authentication is required to access this page.")
        case "rate_limited":
            return ErrorClassification(
                icon: "clock.badge.exclamationmark", title: "Rate Limited",
                code: codeLabel ?? "HTTP 429",
                suggestion: "Too many requests. Try again in a moment.")
        case "server_error":
            return ErrorClassification(
                icon: "server.rack", title: "Server Error",
                code: codeLabel ?? "HTTP 500",
                suggestion: "The remote server encountered an error.")
        case "timeout":
            return ErrorClassification(
                icon: "clock.arrow.circlepath", title: "Request Timed Out",
                code: nil,
                suggestion: "The page took too long to respond. Try again later.")
        case "dns":
            return ErrorClassification(
                icon: "wifi.slash", title: "DNS Error", code: nil,
                suggestion: "Could not resolve the domain. Check the URL is correct.")
        case "ssl":
            return ErrorClassification(
                icon: "lock.trianglebadge.exclamationmark", title: "SSL Error", code: nil,
                suggestion: "There was a problem with the site's security certificate.")
        case "redirect":
            return ErrorClassification(
                icon: "arrow.triangle.turn.up.right.diamond", title: "Redirect Detected", code: nil,
                suggestion: "The page redirected to a different host. Try fetching the redirect URL.")
        case "blocked":
            return ErrorClassification(
                icon: "shield.slash", title: "Domain Blocked", code: nil,
                suggestion: "This domain is blocked from being fetched.")
        case "too_large":
            return ErrorClassification(
                icon: "scalemass", title: "Response Too Large", code: nil,
                suggestion: "The response exceeded the maximum allowed size.")
        case "invalid_url":
            return ErrorClassification(
                icon: "link.badge.plus", title: "Invalid URL", code: nil,
                suggestion: "The URL could not be parsed. Check formatting.")
        case "network":
            return ErrorClassification(
                icon: "network.slash", title: "Network Error", code: nil,
                suggestion: "A network-level error prevented the fetch.")
        default:
            return ErrorClassification(
                icon: "exclamationmark.triangle.fill", title: "Fetch Failed", code: codeLabel,
                suggestion: "An error occurred while fetching the page.")
        }
    }

    /// Whether the response came from cache. Reads `details.fromCache`.
    static func isCached(details: [String: AnyCodable]?) -> Bool {
        details?["fromCache"]?.value as? Bool == true
    }
}
