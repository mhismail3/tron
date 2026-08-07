import Foundation

/// Selects a safe, cohesive artifact renderer from verified bytes.
///
/// Text stays inside Tron's own typography and sheet hierarchy. Native Quick
/// Look remains the fallback for format-owned binary documents. Very large
/// Markdown is shown as efficient selectable text instead of synchronously
/// constructing an unbounded SwiftUI block tree.
enum ArtifactPreviewContent: Equatable {
    case markdown(String)
    case text(String, monospaced: Bool)
    case quickLook

    static let maximumRichMarkdownBytes = 256 * 1_024

    static func resolve(
        mediaType: String,
        displayName: String,
        data: Data
    ) -> Self {
        let normalizedMediaType = mediaType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let pathExtension = URL(fileURLWithPath: displayName)
            .pathExtension
            .lowercased()

        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return .quickLook
        }

        let isMarkdown = normalizedMediaType == "text/markdown"
            || pathExtension == "md"
            || pathExtension == "markdown"
        if isMarkdown, data.count <= maximumRichMarkdownBytes {
            return .markdown(text)
        }

        let structuredTextTypes: Set<String> = [
            "application/json",
            "application/ld+json",
            "application/javascript",
            "application/xml",
            "application/yaml",
            "application/x-yaml",
            "text/csv",
            "text/tab-separated-values",
            "text/html",
            "text/css",
            "text/javascript"
        ]
        let structuredExtensions: Set<String> = [
            "csv", "css", "html", "htm", "js", "json", "jsonl",
            "toml", "tsv", "xml", "yaml", "yml"
        ]
        let isText = normalizedMediaType.hasPrefix("text/")
            || structuredTextTypes.contains(normalizedMediaType)
            || isMarkdown
        guard isText else { return .quickLook }

        return .text(
            text,
            monospaced: structuredTextTypes.contains(normalizedMediaType)
                || structuredExtensions.contains(pathExtension)
        )
    }
}
