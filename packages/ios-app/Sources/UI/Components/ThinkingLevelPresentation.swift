import Foundation

enum ThinkingLevelPresentation {
    static func title(_ level: String) -> String {
        let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
        if key == "xhigh" || key == "extrahigh" { return "Extra High" }
        return trimmed.capitalized
    }
}
