import Foundation

/// Sanitization shared by retained interactive extension frames. Ambient
/// extension widgets are retired, but native interaction content still uses
/// these bounded text and URL rules.
enum NativeExtensionText {
    private static let navigationGlyphs = "↓←→↑↔⇣⇡⇠⇢"

    static func isDetailHint(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.range(
            of: #"^press\b[^\n]*\blive\s+detail\b\s*[.!…]*$"#,
            options: .regularExpression.union(.caseInsensitive)
        ) != nil { return true }
        guard text.range(
            of: #"\bto\s+inspect\b"#,
            options: .regularExpression.union(.caseInsensitive)
        ) != nil else { return false }
        return text.unicodeScalars.contains { navigationGlyphs.unicodeScalars.contains($0) }
    }

    static func clean(_ raw: String) -> String {
        guard !isDetailHint(raw) else { return "" }
        return raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" { return url.host == nil ? nil : url }
        return url
    }
}
