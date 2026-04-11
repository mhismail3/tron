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
        // Extract family name and version from IDs like "claude-opus-4-6-20260410"
        let families: [(keyword: String, name: String)] = [
            ("opus", "Opus"),
            ("sonnet", "Sonnet"),
            ("haiku", "Haiku"),
        ]
        for family in families {
            guard lower.contains(family.keyword) else { continue }
            // Match version digits after the family name: e.g. "opus-4-6" → "4.6"
            if let range = lower.range(of: "\(family.keyword)-([0-9]+(?:-[0-9]+)*)", options: .regularExpression) {
                let versionPart = lower[range].dropFirst(family.keyword.count + 1) // drop "opus-"
                let version = versionPart.replacingOccurrences(of: "-", with: ".")
                return "\(family.name) \(version)"
            }
            return family.name
        }
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
