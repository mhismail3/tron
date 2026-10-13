import Foundation

/// Where a staged annotation was selected. Presentation-only: it drives the
/// transcript highlight for the exact assistant text block and is never sent.
struct ChatAnnotationAnchor: Hashable, Sendable {
    let itemID: String
    /// `ChatAnnotationSource.blockKey`: the text part plus the markdown block.
    let blockKey: String
    /// UTF-16 range in that block's rendered text.
    let location: Int
    let length: Int

    var range: NSRange { NSRange(location: location, length: length) }
}

/// One quoted passage of an assistant response and the maintainer's comment.
/// Staged annotations belong to the composer draft scope; sent annotations are
/// recovered from the canonical prompt text by `ChatAnnotationEnvelope`.
struct ChatAnnotation: Identifiable, Hashable, Sendable {
    let id: String
    let quote: String
    var comment: String
    let anchor: ChatAnnotationAnchor?

    init(id: String = UUID().uuidString, quote: String, comment: String, anchor: ChatAnnotationAnchor?) {
        self.id = id
        self.quote = quote
        self.comment = comment
        self.anchor = anchor
    }
}

/// The prompt-text contract for annotations. The model receives each one as a
/// tagged Markdown blockquote of its own words followed by the comment, ahead
/// of the typed message. No Gateway or protocol field is involved: the
/// canonical user message stores exactly this text, and the app recovers the
/// structure from it for display. Anything that does not parse exactly is
/// shown as ordinary prompt text.
enum ChatAnnotationEnvelope {
    static let open = "<annotation>"
    static let close = "</annotation>"

    static func compose(annotations: [ChatAnnotation], body: String) -> String {
        guard !annotations.isEmpty else { return body }
        let blocks = annotations.map { annotation -> String in
            let quote = annotation.quote
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            let comment = annotation.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            return comment.isEmpty
                ? "\(open)\n\(quote)\n\(close)"
                : "\(open)\n\(quote)\n\n\(comment)\n\(close)"
        }
        let envelope = blocks.joined(separator: "\n")
        return body.isEmpty ? envelope : "\(envelope)\n\n\(body)"
    }

    struct Parsed: Equatable {
        let annotations: [ChatAnnotation]
        let body: String
    }

    /// Returns nil unless the text begins with at least one well-formed block.
    static func parse(_ text: String) -> Parsed? {
        guard text.hasPrefix(open + "\n") else { return nil }
        var remainder = Substring(text)
        var annotations: [ChatAnnotation] = []
        while remainder.hasPrefix(open + "\n") {
            remainder = remainder.dropFirst(open.count + 1)
            guard let end = remainder.range(of: "\n" + close) else { return nil }
            let inner = remainder[..<end.lowerBound]
            remainder = remainder[end.upperBound...]
            guard remainder.isEmpty || remainder.hasPrefix("\n") else { return nil }
            var quoteLines: [String] = []
            var lines = inner.split(separator: "\n", omittingEmptySubsequences: false)[...]
            while let line = lines.first, line.hasPrefix(">") {
                quoteLines.append(String(line.hasPrefix("> ") ? line.dropFirst(2) : line.dropFirst()))
                lines = lines.dropFirst()
            }
            guard !quoteLines.isEmpty else { return nil }
            if let separator = lines.first {
                guard separator.isEmpty else { return nil }
                lines = lines.dropFirst()
            }
            annotations.append(ChatAnnotation(
                id: "sent-annotation-\(annotations.count)",
                quote: quoteLines.joined(separator: "\n"),
                comment: lines.joined(separator: "\n"),
                anchor: nil
            ))
            if remainder.hasPrefix("\n" + open + "\n") { remainder = remainder.dropFirst() }
        }
        if remainder.hasPrefix("\n\n") { remainder = remainder.dropFirst(2) }
        else if remainder.hasPrefix("\n") { remainder = remainder.dropFirst() }
        return Parsed(annotations: annotations, body: String(remainder))
    }

    /// Display text for surfaces that show only the typed message.
    static func body(of text: String) -> String {
        parse(text)?.body ?? text
    }
}
