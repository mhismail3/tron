import Foundation

// MARK: - Token Formatter

/// Unified token count formatting.
/// Consolidates duplicate formatting logic from ContextAuditView, EventTypes, and RPCTypes.
enum TokenFormatter {

    /// Output format for token counts
    enum Style {
        /// Compact lowercase: "1.5k", "2.3M"
        case compact
        /// Uppercase with suffix: "1.5K tokens", "2.3M tokens"
        case withSuffix
        /// Uppercase without suffix: "1.5K", "2.3M"
        case uppercase
    }

    /// Format a token count to the specified style
    /// - Parameters:
    ///   - count: The token count to format
    ///   - style: The desired output format
    /// - Returns: Formatted token count string
    static func format(_ count: Int, style: Style = .compact) -> String {
        switch style {
        case .compact:
            return formatCompact(count)
        case .withSuffix:
            return formatWithSuffix(count)
        case .uppercase:
            return formatUppercase(count)
        }
    }

    /// Format input/output token pair with arrows: "↓1.2k ↑3.4k"
    /// - Parameters:
    ///   - input: Input token count
    ///   - output: Output token count
    /// - Returns: Formatted string with arrows
    static func formatPair(input: Int, output: Int) -> String {
        let inStr = format(input, style: .compact)
        let outStr = format(output, style: .compact)
        return "↓\(inStr) ↑\(outStr)"
    }

    /// Format full session tokens including cache: "↓1.2k ↑3.4k ✓20.3k ⚡8.0k"
    /// - Parameters:
    ///   - input: Input token count
    ///   - output: Output token count
    ///   - cacheRead: Cache read tokens (nil or 0 to hide)
    ///   - cacheWrite: Cache write/creation tokens (nil or 0 to hide)
    /// - Returns: Formatted string with arrows and optional cache indicators
    static func formatFullSession(input: Int, output: Int, cacheRead: Int?, cacheWrite: Int?) -> String {
        var result = formatPair(input: input, output: output)

        // Add cache read if non-zero
        if let read = cacheRead, read > 0 {
            result += " ✓\(format(read, style: .compact))"
        }

        // Add cache write if non-zero
        if let write = cacheWrite, write > 0 {
            result += " ⚡\(format(write, style: .compact))"
        }

        return result
    }

    // MARK: - Private

    private static func formatCompact(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private static func formatWithSuffix(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK tokens", Double(count) / 1_000)
        }
        return "\(count) tokens"
    }

    private static func formatUppercase(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Int Extension

extension Int {
    /// Compact token format: "1.5k", "2.3M"
    var formattedTokenCount: String {
        TokenFormatter.format(self, style: .compact)
    }

    /// Token format with suffix: "1.5K tokens"
    var formattedTokensWithSuffix: String {
        TokenFormatter.format(self, style: .withSuffix)
    }
}
