import Foundation
import TronMobileCore

struct ChangeReviewPresentation {
    struct Item {
        let label: String
        let before: String
        let after: String
        let note: String?
    }

    struct TechnicalSection: Identifiable {
        let title: String
        let facts: [TronTechnicalMetadataItem]
        let exact: String?
        var id: String { title }
    }

    let title: String
    let reason: String?
    let items: [Item]
    let change: [TronTechnicalMetadataItem]
    let technical: [TechnicalSection]

    init(_ review: ChangeReview) {
        title = Self.settingTitle(review) ?? Self.readable(review.title)
        reason = review.reason
        items = review.items.map { item in
            Item(label: Self.readable(item.label), before: Self.readable(item.before), after: Self.readable(item.after),
                 note: Self.detail(item.detail).note)
        }
        change = [
            TronTechnicalMetadataItem(title: "Title", value: review.title, icon: "text.alignleft"),
            TronTechnicalMetadataItem(title: "Digest", value: review.digest, icon: "number"),
        ]
        technical = review.items.map { item in
            var facts = [
                TronTechnicalMetadataItem(title: "Before", value: item.before, icon: "arrow.uturn.backward"),
                TronTechnicalMetadataItem(title: "After", value: item.after, icon: "arrow.forward"),
            ]
            if let scope = Self.detail(item.detail).scope {
                facts.append(TronTechnicalMetadataItem(title: "Scope", value: scope, icon: "scope"))
            }
            return TechnicalSection(title: item.label, facts: facts, exact: item.exact)
        }
    }

    private static func detail(_ text: String?) -> (scope: String?, note: String?) {
        let lines = (text ?? "").split(separator: "\n").map(String.init)
        let notes = lines.filter { $0.hasSuffix(".") }
        let scope = lines.filter { !$0.hasSuffix(".") }
        return (scope.isEmpty ? nil : scope.joined(separator: "\n"), notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    private static func settingTitle(_ review: ChangeReview) -> String? {
        guard review.items.count == 1, let item = review.items.first, let exact = item.exact,
              let fields = (try? JSONValue.wire(exact))?.objectValue, fields["key"]?.stringValue != nil,
              let qualifiers = fields["qualifiers"]?.objectValue, qualifiers.count == 1,
              let name = qualifiers.values.first?.stringValue else { return nil }
        let removes = fields["op"]?.stringValue == "unset" || fields["after"] == .null
        let verb = removes ? "Remove" : fields["before"] == .null ? "Add" : "Change"
        return "\(verb) \(name) \(item.label)"
    }

    static func readable(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { readableToken(String($0)) }.joined(separator: " ")
    }

    private static func readableToken(_ token: String) -> String {
        for prefix in ["git:", "npm:"] where token.hasPrefix(prefix) {
            let locator = String(token.dropFirst(prefix.count))
            if let at = locator.lastIndex(of: "@"), at > (locator.lastIndex(of: "/") ?? locator.startIndex) {
                return "\(name(String(locator[..<at]))) @ \(shortHash(String(locator[locator.index(after: at)...])))"
            }
            return name(locator)
        }
        return shortHash(token)
    }

    private static func name(_ locator: String) -> String {
        let last = locator.split(separator: "/").last.map(String.init) ?? locator
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    private static func shortHash(_ token: String) -> String {
        token.count >= 12 && token.count <= 64 && token.allSatisfy(\.isHexDigit)
            && token.contains(where: \.isNumber) && token.contains(where: \.isLetter)
            ? String(token.prefix(7)) : token
    }
}
