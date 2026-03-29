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
            // Source Header (with method badge for raw mode)
            if let source = parsedResult.source {
                SourceHeader(source: source, mode: parsedResult.mode)
            }

            // Raw mode: status code display
            if let status = parsedResult.httpStatus {
                HttpStatusBadge(status: status, method: parsedResult.httpMethod ?? "GET")
            }

            // Error Display (summarization mode only — raw mode non-2xx is not an error)
            if let error = parsedResult.error {
                WebFetchErrorBanner(message: error)
            } else if !parsedResult.answer.isEmpty {
                // Answer/Body Content
                AnswerSection(answer: parsedResult.answer, isExpanded: $isExpanded)
            }

            // Metadata Footer (summarization mode only)
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
    var mode: WebFetchMode = .summarization

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: isRawMode ? "network" : "globe")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronInfo)

                // Show method badge in raw mode
                if case .raw(let method, _) = mode, method != "GET" {
                    Text(method)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(methodColor(method))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

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

    private var isRawMode: Bool {
        if case .raw = mode { return true }
        return false
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "POST": return .tronInfo
        case "PUT": return .tronAmber
        case "PATCH": return .tronAmber
        case "DELETE": return .tronError
        case "HEAD": return .tronTextMuted
        default: return .tronInfo
        }
    }
}

/// HTTP status code badge for raw mode results.
private struct HttpStatusBadge: View {
    let status: Int
    let method: String

    private var statusColor: Color {
        switch status {
        case 200..<300: return .tronEmerald
        case 300..<400: return .tronAmber
        case 400..<500: return .tronError
        case 500...: return .tronError
        default: return .tronTextMuted
        }
    }

    private var statusText: String {
        switch status {
        case 200: return "200 OK"
        case 201: return "201 Created"
        case 204: return "204 No Content"
        case 301: return "301 Moved"
        case 302: return "302 Found"
        case 304: return "304 Not Modified"
        case 400: return "400 Bad Request"
        case 401: return "401 Unauthorized"
        case 403: return "403 Forbidden"
        case 404: return "404 Not Found"
        case 429: return "429 Rate Limited"
        case 500: return "500 Server Error"
        case 502: return "502 Bad Gateway"
        case 503: return "503 Unavailable"
        default: return "\(status)"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(statusColor)
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

/// Whether the WebFetch result is from summarization mode or raw HTTP mode.
enum WebFetchMode {
    /// Legacy summarization mode (GET + prompt → parse HTML → summarize)
    case summarization
    /// Raw HTTP mode (any method, returns status + headers + body)
    case raw(method: String, status: Int?)
}

struct WebFetchParsedResult {
    let answer: String
    let source: WebFetchSource?
    let error: String?
    let metadata: WebFetchMetadata?
    let mode: WebFetchMode

    /// Detect mode from arguments: if method is present and not GET,
    /// or rawResponse is true, or prompt is absent → raw mode.
    static func detectMode(arguments: String) -> WebFetchMode {
        let method = ToolArgumentParser.string("method", from: arguments)?.uppercased()
        let rawResponse = ToolArgumentParser.boolean("rawResponse", from: arguments) ?? false
        let prompt = ToolArgumentParser.string("prompt", from: arguments)

        let isRaw = rawResponse || method != nil && method != "GET" || prompt == nil
        if isRaw {
            return .raw(method: method ?? "GET", status: nil)
        }
        return .summarization
    }

    init(from result: String, arguments: String) {
        let detectedMode = Self.detectMode(arguments: arguments)
        let source = Self.extractSource(from: result, arguments: arguments)

        switch detectedMode {
        case .summarization:
            // Legacy behavior: parse answer, errors, metadata from result text
            if result.hasPrefix("Error:") || result.contains("\"error\"") {
                self.error = Self.extractError(from: result)
                self.answer = ""
                self.metadata = nil
            } else {
                self.answer = Self.extractAnswer(from: result)
                self.error = nil
                self.metadata = Self.extractMetadata(from: result)
            }
            self.source = source
            self.mode = .summarization

        case .raw(let method, _):
            // Raw HTTP mode: parse "HTTP {status} {url}\n\n{body}" format
            let (status, body) = Self.parseRawResponse(result)
            self.answer = body
            self.error = nil
            self.metadata = nil
            self.source = source
            self.mode = .raw(method: method, status: status)
        }
    }

    // MARK: - Raw HTTP Parsing

    /// Parse "HTTP {status} {url}\n\n{body}" format from raw mode output.
    private static func parseRawResponse(_ result: String) -> (status: Int?, body: String) {
        // Check for "HTTP {status} " prefix
        if result.hasPrefix("HTTP ") {
            // Find the end of the status line
            if let newlineRange = result.range(of: "\n\n") {
                let statusLine = String(result[result.startIndex..<newlineRange.lowerBound])
                let body = String(result[newlineRange.upperBound...])

                // Extract status code: "HTTP 200 https://..."
                let parts = statusLine.components(separatedBy: " ")
                let status = parts.count >= 2 ? Int(parts[1]) : nil
                return (status, body.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (nil, result)
    }

    // MARK: - Summarization Parsing (legacy)

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
        // Extract URL from arguments via ToolArgumentParser
        let url = ToolArgumentParser.url(from: arguments)
        guard !url.isEmpty else { return nil }

        // Extract title from result if present (summarization mode)
        var title = ""
        if let match = result.firstMatch(of: /Title:\s*(.+)/) {
            title = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let domain = ToolArgumentParser.extractDomain(from: url)

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
        var sessionId: String?
        if let match = result.firstMatch(of: /subagentSessionId["\s:]+([a-zA-Z0-9_-]+)/) {
            sessionId = String(match.1)
        }
        guard sessionId != nil else { return nil }
        return WebFetchMetadata(fetchedAt: nil, subagentSessionId: sessionId)
    }

    // MARK: - Helpers

    /// Whether this is a raw HTTP mode result.
    var isRawMode: Bool {
        if case .raw = mode { return true }
        return false
    }

    /// HTTP method for raw mode, nil for summarization.
    var httpMethod: String? {
        if case .raw(let method, _) = mode { return method }
        return nil
    }

    /// HTTP status code for raw mode, nil for summarization.
    var httpStatus: Int? {
        if case .raw(_, let status) = mode { return status }
        return nil
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

#Preview("WebFetch - Summarization") {
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
}

#Preview("WebFetch - Raw HTTP POST") {
    WebFetchResultViewer(
        result: "HTTP 201 https://api.example.com/items\n\n{\"id\": 42, \"name\": \"New Item\", \"created\": true}",
        arguments: "{\"url\": \"https://api.example.com/items\", \"method\": \"POST\", \"body\": {\"name\": \"New Item\"}}",
        isExpanded: .constant(false)
    )
    .padding()
    .background(Color.tronBackground)
}

#Preview("WebFetch - Raw HTTP GET") {
    WebFetchResultViewer(
        result: "HTTP 200 https://api.example.com/health\n\n{\"status\": \"ok\", \"uptime\": 12345}",
        arguments: "{\"url\": \"https://api.example.com/health\", \"rawResponse\": true}",
        isExpanded: .constant(false)
    )
    .padding()
    .background(Color.tronBackground)
}
