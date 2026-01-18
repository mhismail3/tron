import Foundation

/// Parses and validates GitHub repository URLs.
/// Supports various URL formats and normalizes them to HTTPS.
enum GitHubURLParser {
    /// Result of parsing a GitHub URL
    struct ParseResult {
        /// Repository owner (username or organization)
        let owner: String
        /// Repository name (without .git suffix)
        let repoName: String
        /// Normalized HTTPS URL for cloning
        let normalizedURL: String
    }

    /// GitHub URL pattern - supports various formats
    /// - https://github.com/owner/repo
    /// - https://github.com/owner/repo.git
    /// - github.com/owner/repo
    /// - www.github.com/owner/repo
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"^(?:https?://)?(?:www\.)?github\.com/([^/]+)/([^/]+?)(?:\.git)?$"#,
        options: [.caseInsensitive]
    )

    /// Parses a GitHub URL and extracts owner/repo information.
    /// - Parameter url: The URL string to parse
    /// - Returns: ParseResult if valid, nil if invalid
    static func parse(_ url: String) -> ParseResult? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = urlPattern.firstMatch(in: trimmed, options: [], range: range) else {
            return nil
        }

        // Extract owner (capture group 1)
        guard let ownerRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        let owner = String(trimmed[ownerRange])

        // Extract repo name (capture group 2)
        guard let repoRange = Range(match.range(at: 2), in: trimmed) else {
            return nil
        }
        var repoName = String(trimmed[repoRange])

        // Remove .git suffix if present
        if repoName.lowercased().hasSuffix(".git") {
            repoName = String(repoName.dropLast(4))
        }

        // Normalize to HTTPS URL
        let normalizedURL = "https://github.com/\(owner)/\(repoName).git"

        return ParseResult(
            owner: owner,
            repoName: repoName,
            normalizedURL: normalizedURL
        )
    }

    /// Checks if a URL is a valid GitHub repository URL.
    /// - Parameter url: The URL string to validate
    /// - Returns: true if valid, false otherwise
    static func isValid(_ url: String) -> Bool {
        return parse(url) != nil
    }

    /// Returns an error message if the URL is invalid, nil if valid.
    /// - Parameter url: The URL string to validate
    /// - Returns: Error message string if invalid, nil if valid
    static func validationError(for url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return "Enter a GitHub URL"
        }

        guard isValid(trimmed) else {
            return "Enter a valid GitHub URL (e.g., github.com/owner/repo)"
        }

        return nil
    }
}
