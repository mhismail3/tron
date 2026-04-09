import SwiftUI

/// Displays WebFetch tool results with source attribution and formatted answer.
///
/// Reads every structured field from server-provided `tool.details`:
/// `mode`, `answer`, `body`, `httpStatus`, `method`, `url`, `title`,
/// `fromCache`, `subagentSessionId`, `error`, `errorClass`. No text parsing.
struct WebFetchResultViewer: View {
    let details: [String: AnyCodable]?
    let arguments: String
    @Binding var isExpanded: Bool

    private var parsedResult: WebFetchParsedResult {
        WebFetchParsedResult(details: details, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let source = parsedResult.source {
                SourceHeader(source: source, mode: parsedResult.mode)
            }

            if let status = parsedResult.httpStatus {
                HttpStatusBadge(status: status, method: parsedResult.httpMethod ?? "GET")
            }

            if let error = parsedResult.error {
                WebFetchErrorBanner(message: error)
            } else if !parsedResult.displayContent.isEmpty {
                AnswerSection(answer: parsedResult.displayContent, isExpanded: $isExpanded)
            }

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
                    .font(TronTypography.codeContent)
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
enum WebFetchMode: Equatable {
    case summarization
    case raw(method: String, status: Int?)
}

/// WebFetch result parsed from server-provided `tool.details`.
///
/// The server (`packages/agent/src/tools/web/web_fetch.rs`) populates every
/// field below. iOS does not scan text. See
/// `WebFetchDetailParser` for error decoding.
struct WebFetchParsedResult {
    /// Primary display content: summarization answer OR raw response body.
    let displayContent: String
    let source: WebFetchSource?
    let error: String?
    let metadata: WebFetchMetadata?
    let mode: WebFetchMode
    /// Whether the result came from cache (summarization only).
    let isCached: Bool

    init(details: [String: AnyCodable]?, arguments: String) {
        let modeString = details?["mode"]?.value as? String
        let url = ToolArgumentParser.url(from: arguments)
        let title = (details?["title"]?.value as? String) ?? ""
        let domain = ToolArgumentParser.extractDomain(from: url)

        self.source = url.isEmpty
            ? nil
            : WebFetchSource(url: url, domain: domain, title: title)
        self.error = WebFetchDetailParser.errorMessage(from: details)
        self.isCached = WebFetchDetailParser.isCached(details: details)

        let httpStatus: Int? = {
            if let i = details?["httpStatus"]?.value as? Int { return i }
            if let d = details?["httpStatus"]?.value as? Double { return Int(d) }
            return nil
        }()

        if modeString == "raw" {
            let method = (details?["method"]?.value as? String) ?? "GET"
            self.mode = .raw(method: method, status: httpStatus)
            self.displayContent = (details?["body"]?.value as? String) ?? ""
            self.metadata = nil
        } else {
            // Summarization (default when mode absent, e.g. errors before mode was set)
            self.mode = .summarization
            self.displayContent = (details?["answer"]?.value as? String) ?? ""
            let sessionId = details?["subagentSessionId"]?.value as? String
            if let sid = sessionId, !sid.isEmpty {
                self.metadata = WebFetchMetadata(fetchedAt: nil, subagentSessionId: sid)
            } else {
                self.metadata = nil
            }
        }
    }

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

#if DEBUG
#Preview("WebFetch - Summarization") {
    let summarizationDetails: [String: AnyCodable] = [
        "mode": AnyCodable("summarization"),
        "url": AnyCodable("https://docs.anthropic.com/en/docs/about-claude/models"),
        "title": AnyCodable("Claude Models - Anthropic Documentation"),
        "answer": AnyCodable("""
            Claude has three main model families available:

            1. **Claude 3.5 Sonnet** - The most intelligent model, best for complex tasks
            2. **Claude 3.5 Haiku** - Fast and cost-effective for simple tasks
            3. **Claude 3 Opus** - High capability for demanding applications
            """),
        "fromCache": AnyCodable(false),
        "subagentSessionId": AnyCodable("sub-sess-abc"),
    ]
    let errorDetails: [String: AnyCodable] = [
        "error": AnyCodable("HTTP 404 for https://example.com/nonexistent"),
        "errorClass": AnyCodable("not_found"),
        "httpStatus": AnyCodable(404),
    ]
    return VStack(spacing: 16) {
        WebFetchResultViewer(
            details: summarizationDetails,
            arguments: "{\"url\": \"https://docs.anthropic.com/en/docs/about-claude/models\", \"prompt\": \"What models are available?\"}",
            isExpanded: .constant(false)
        )

        WebFetchResultViewer(
            details: errorDetails,
            arguments: "{\"url\": \"https://example.com/nonexistent\", \"prompt\": \"Read this page\"}",
            isExpanded: .constant(false)
        )
    }
    .padding()
    .background(Color.tronBackground)
}

#Preview("WebFetch - Raw HTTP POST") {
    let details: [String: AnyCodable] = [
        "mode": AnyCodable("raw"),
        "url": AnyCodable("https://api.example.com/items"),
        "method": AnyCodable("POST"),
        "httpStatus": AnyCodable(201),
        "body": AnyCodable("{\"id\": 42, \"name\": \"New Item\", \"created\": true}"),
    ]
    return WebFetchResultViewer(
        details: details,
        arguments: "{\"url\": \"https://api.example.com/items\", \"method\": \"POST\", \"body\": {\"name\": \"New Item\"}}",
        isExpanded: .constant(false)
    )
    .padding()
    .background(Color.tronBackground)
}
#endif
