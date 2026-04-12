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
        if source == "chat" { return "Chat" }
        if let title = title, !title.isEmpty {
            return title
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
        latestModel.shortModelName
    }

    var displayDirectory: String {
        // Server paths are macOS paths — NSString.abbreviatingWithTildeInPath
        // only matches the iOS home dir, so replace /Users/<name>/ manually.
        if let range = workingDirectory.range(of: #"^/Users/[^/]+"#, options: .regularExpression) {
            return "~" + workingDirectory[range.upperBound...]
        }
        return workingDirectory
    }

    /// Unique workspace paths from a list of sessions, ordered by first appearance.
    /// Sessions should be pre-sorted (e.g. by most recent activity).
    /// Filters out sessions with empty workingDirectory.
    static func recentWorkspaces(from sessions: [CachedSession]) -> [(path: String, name: String)] {
        var seen = Set<String>()
        var result: [(path: String, name: String)] = []
        for session in sessions {
            let path = session.workingDirectory
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            result.append((path: path, name: name))
        }
        return result
    }
}
