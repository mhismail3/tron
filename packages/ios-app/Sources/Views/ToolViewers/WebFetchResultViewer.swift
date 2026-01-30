import SwiftUI

/// Displays WebFetch tool results with source attribution and formatted answer
struct WebFetchResultViewer: View {
    let result: String
    let arguments: String
    @Binding var isExpanded: Bool

    private var parsedResult: WebFetchParsedResult {
        WebFetchParsedResult(from: result, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Source Header
            if let source = parsedResult.source {
                SourceHeader(source: source)
            }

            // Error Display
            if let error = parsedResult.error {
                WebFetchErrorBanner(message: error)
            } else if !parsedResult.answer.isEmpty {
                // Answer Content
                AnswerSection(answer: parsedResult.answer, isExpanded: $isExpanded)
            }

            // Metadata Footer
            if let metadata = parsedResult.metadata, metadata.subagentSessionId != nil {
                MetadataFooter(metadata: metadata)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Subviews

private struct SourceHeader: View {
    let source: WebFetchSource

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronInfo)
                Text(source.title.isEmpty ? source.domain : source.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
            }

            if !source.url.isEmpty {
                Text(source.url)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
            }
        }
    }
}

private struct AnswerSection: View {
    let answer: String
    @Binding var isExpanded: Bool

    private var displayAnswer: String {
        if isExpanded {
            return answer
        } else {
            let lines = answer.components(separatedBy: "\n")
            if lines.count > 10 {
                return lines.prefix(10).joined(separator: "\n") + "\n..."
            }
            return answer
        }
    }

    private var needsExpansion: Bool {
        answer.components(separatedBy: "\n").count > 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayAnswer)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .regular))
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if needsExpansion {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded ? "Show less" : "Show more")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronInfo)
                }
            }
        }
    }
}

private struct WebFetchErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronWarning)
            Text(message)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .regular))
                .foregroundStyle(.tronWarning)
        }
        .padding(8)
        .background(Color.tronWarning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct MetadataFooter: View {
    let metadata: WebFetchMetadata

    var body: some View {
        HStack(spacing: 12) {
            if let fetchedAt = metadata.fetchedAt {
                Label(fetchedAt, systemImage: "clock")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)
            }
            if let sessionId = metadata.subagentSessionId {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.codeCaption)
                    Text("Subagent: \(String(sessionId.prefix(8)))...")
                        .font(TronTypography.codeCaption)
                }
                .foregroundStyle(.tronTextMuted)
            }
        }
    }
}

// MARK: - Data Models

struct WebFetchParsedResult {
    let answer: String
    let source: WebFetchSource?
    let error: String?
    let metadata: WebFetchMetadata?

    init(from result: String, arguments: String) {
        // Check for error first
        if result.hasPrefix("Error:") || result.contains("\"error\"") {
            self.error = Self.extractError(from: result)
            self.answer = ""
            self.source = Self.extractSource(from: result, arguments: arguments)
            self.metadata = nil
        } else {
            self.answer = Self.extractAnswer(from: result)
            self.source = Self.extractSource(from: result, arguments: arguments)
            self.error = nil
            self.metadata = Self.extractMetadata(from: result)
        }
    }

    private static func extractAnswer(from result: String) -> String {
        var content = result

        // Remove source attribution section if present
        if let range = content.range(of: "\n\nSource:") {
            content = String(content[..<range.lowerBound])
        }
        if let range = content.range(of: "\n\n---") {
            content = String(content[..<range.lowerBound])
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractSource(from result: String, arguments: String) -> WebFetchSource? {
        // Extract URL from arguments
        var url = ""
        if let match = arguments.firstMatch(of: /"url"\s*:\s*"([^"]+)"/) {
            url = String(match.1)
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }

        // Extract title from result if present
        var title = ""
        if let match = result.firstMatch(of: /Title:\s*(.+)/) {
            title = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !url.isEmpty else { return nil }

        // Extract domain from URL
        let domain: String
        if let urlObj = URL(string: url), let host = urlObj.host {
            domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else {
            domain = url
        }

        return WebFetchSource(url: url, domain: domain, title: title)
    }

    private static func extractError(from result: String) -> String {
        if result.hasPrefix("Error:") {
            return String(result.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = result.firstMatch(of: /"error"\s*:\s*"([^"]+)"/) {
            return String(match.1)
        }
        return result
    }

    private static func extractMetadata(from result: String) -> WebFetchMetadata? {
        // Look for subagent session ID in result
        var sessionId: String?
        if let match = result.firstMatch(of: /subagentSessionId["\s:]+([a-zA-Z0-9_-]+)/) {
            sessionId = String(match.1)
        }

        guard sessionId != nil else { return nil }
        return WebFetchMetadata(fetchedAt: nil, subagentSessionId: sessionId)
    }
}

struct WebFetchSource {
    let url: String
    let domain: String
    let title: String
}

struct WebFetchMetadata {
    let fetchedAt: String?
    let subagentSessionId: String?
}

// MARK: - Preview

#Preview("WebFetch Success") {
    VStack(spacing: 16) {
        WebFetchResultViewer(
            result: """
            Claude has three main model families available:

            1. **Claude 3.5 Sonnet** - The most intelligent model, best for complex tasks
            2. **Claude 3.5 Haiku** - Fast and cost-effective for simple tasks
            3. **Claude 3 Opus** - High capability for demanding applications

            Source: https://docs.anthropic.com/en/docs/about-claude/models
            Title: Claude Models - Anthropic Documentation
            """,
            arguments: "{\"url\": \"https://docs.anthropic.com/en/docs/about-claude/models\", \"prompt\": \"What models are available?\"}",
            isExpanded: .constant(false)
        )

        WebFetchResultViewer(
            result: "Error: HTTP 404 - Page not found",
            arguments: "{\"url\": \"https://example.com/nonexistent\", \"prompt\": \"Read this page\"}",
            isExpanded: .constant(false)
        )
    }
    .padding()
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
