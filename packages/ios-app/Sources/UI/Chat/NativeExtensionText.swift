import Foundation

/// Sanitization shared by retained interactive extension frames. Ambient
/// extension widgets are retired, but native interaction content still uses
/// these bounded text and URL rules.
enum NativeExtensionText {
    private static let navigationGlyphs = "↓←→↑↔⇣⇡⇠⇢"

    // Compiled once. These run per frame line on the render path, and a frame may
    // carry 120 lines and 4096 runs, so per-call ICU pattern compilation was the
    // dominant cost of drawing one large frame. The literals stay the single
    // source of each pattern: they are the fallback if compilation ever fails.
    private static let pressHintLiteral = #"^press\b[^\n]*\blive\s+detail\b\s*[.!…]*$"#
    private static let inspectHintLiteral = #"\bto\s+inspect\b"#
    private static let collapseLiteral = #"\s+"#
    private static let pressHintPattern = try? NSRegularExpression(pattern: pressHintLiteral, options: [.caseInsensitive])
    private static let inspectHintPattern = try? NSRegularExpression(pattern: inspectHintLiteral, options: [.caseInsensitive])
    private static let collapsePattern = try? NSRegularExpression(pattern: collapseLiteral)

    private static func matches(_ pattern: NSRegularExpression?, _ literal: String, _ text: String) -> Bool {
        guard let pattern else {
            return text.range(of: literal, options: .regularExpression.union(.caseInsensitive)) != nil
        }
        return pattern.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    static func isDetailHint(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if matches(pressHintPattern, pressHintLiteral, text) { return true }
        guard matches(inspectHintPattern, inspectHintLiteral, text) else { return false }
        return text.unicodeScalars.contains { navigationGlyphs.unicodeScalars.contains($0) }
    }

    static func clean(_ raw: String) -> String {
        guard !isDetailHint(raw) else { return "" }
        let collapsed: String
        if let collapsePattern {
            collapsed = collapsePattern.stringByReplacingMatches(
                in: raw,
                options: [],
                range: NSRange(raw.startIndex..<raw.endIndex, in: raw),
                withTemplate: " "
            )
        } else {
            collapsed = raw.replacingOccurrences(of: collapseLiteral, with: " ", options: .regularExpression)
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" { return url.host == nil ? nil : url }
        return url
    }
}
