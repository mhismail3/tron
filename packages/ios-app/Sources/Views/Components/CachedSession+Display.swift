import Foundation

// MARK: - Display Formatting

/// View-layer display extensions for CachedSession.
/// These computed properties format data for presentation and don't belong in the data model.
extension CachedSession {

    var formattedTokens: String {
        TokenFormatter.formatPair(input: totalInputTokens, output: outputTokens)
    }

    var formattedCacheTokens: String? {
        if cacheReadTokens == 0 && cacheCreationTokens == 0 { return nil }
        return "⚡\(cacheReadTokens.formattedTokenCount) read, ✏\(cacheCreationTokens.formattedTokenCount) write"
    }

    var formattedCost: String {
        if cost < 0.01 {
            return "<$0.01"
        }
        return String(format: "$%.2f", cost)
    }

    var displayTitle: String {
        if let title = title, !title.isEmpty {
            return title
        }
        if isChat {
            return "Chat"
        }
        return (workingDirectory as NSString).lastPathComponent
    }

    var formattedDate: String {
        DateParser.formatRelativeOrAbsolute(lastActivityAt)
    }

    var compactDate: String {
        DateParser.formatCompactRelative(lastActivityAt)
    }

    var shortModel: String {
        let lower = latestModel.lowercased()
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        return latestModel
    }

    var displayDirectory: String {
        // Server paths are macOS paths — NSString.abbreviatingWithTildeInPath
        // only matches the iOS home dir, so replace /Users/<name>/ manually.
        if let range = workingDirectory.range(of: #"^/Users/[^/]+"#, options: .regularExpression) {
            return "~" + workingDirectory[range.upperBound...]
        }
        return workingDirectory
    }
}
