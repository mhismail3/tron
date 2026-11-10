import Foundation

enum SessionTitleSearch {
    struct Query {
        let normalized: String
        let tokens: [String]
        var isEmpty: Bool { tokens.isEmpty }

        init(_ raw: String) {
            normalized = SessionTitleSearch.normalize(raw)
            tokens = normalized.split(separator: " ").map(String.init)
        }
    }

    enum Tier: Int, Comparable {
        case exact = 0, prefix, wordPrefix, substring, fuzzy
        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func filter<Item>(_ items: [Item], query raw: String, title: (Item) -> String) -> [Item] {
        let query = Query(raw)
        guard !query.isEmpty else { return items }
        var ranked: [(tier: Tier, index: Int, item: Item)] = []
        for (index, item) in items.enumerated() {
            if let tier = rank(title(item), query: query) { ranked.append((tier, index, item)) }
        }
        ranked.sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.index < $1.index }
        return ranked.map(\.item)
    }

    static func rank(_ title: String, query: Query) -> Tier? {
        guard !query.isEmpty else { return .exact }
        let normalized = normalize(title)
        guard !normalized.isEmpty else { return nil }
        if normalized == query.normalized { return .exact }
        if normalized.hasPrefix(query.normalized) { return .prefix }
        let words = normalized.split(separator: " ")
        var worst = Tier.wordPrefix
        for token in query.tokens {
            guard let tier = tokenTier(token, words: words, normalized: normalized) else { return nil }
            worst = max(worst, tier)
        }
        return worst
    }

    private static func tokenTier(_ token: String, words: [Substring], normalized: String) -> Tier? {
        if words.contains(where: { $0.hasPrefix(token) }) { return .wordPrefix }
        if normalized.contains(token) { return .substring }
        guard token.count >= 3 else { return nil }
        if isAbbreviation(token, of: words) { return .fuzzy }
        if token.count >= 4, words.contains(where: { withinOneEdit(token, prefixOf: $0) }) { return .fuzzy }
        return nil
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        result.reserveCapacity(folded.count)
        var pendingSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingSpace && !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(contentsOf: character.lowercased())
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    private static func isAbbreviation(_ token: String, of words: [Substring]) -> Bool {
        guard let first = token.first else { return false }
        for start in words.indices where words[start].first == first {
            var remaining = token[...]
            for character in words[start...].joined() where character == remaining.first {
                remaining = remaining.dropFirst()
                if remaining.isEmpty { return true }
            }
        }
        return false
    }

    private static func withinOneEdit(_ token: String, prefixOf word: Substring) -> Bool {
        let a = Array(token), b = Array(word)
        guard b.count >= a.count - 1 else { return false }
        for length in [a.count - 1, a.count, a.count + 1] where length <= b.count && length > 0 {
            if editDistanceAtMostOne(a, Array(b.prefix(length))) { return true }
        }
        return false
    }

    private static func editDistanceAtMostOne(_ a: [Character], _ b: [Character]) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if a.count < b.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}
