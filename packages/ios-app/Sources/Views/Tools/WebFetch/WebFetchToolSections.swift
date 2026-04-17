import SwiftUI

// MARK: - WebFetch Source Section

@available(iOS 26.0, *)
struct WebFetchSourceSection: View {
    let url: String
    let domain: String
    let source: WebFetchSource?
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Source", accent: .tronInfo, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle))
                        .foregroundStyle(.tronInfo)

                    if let source, !source.title.isEmpty {
                        Text(source.title)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(tint.name)
                            .lineLimit(2)
                    } else {
                        Text(domain)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(tint.name)
                            .lineLimit(1)
                    }

                    Spacer()
                }

                if !url.isEmpty {
                    Text(url)
                        .font(TronTypography.codeContent)
                        .foregroundStyle(tint.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - WebFetch Prompt Section

@available(iOS 26.0, *)
struct WebFetchPromptSection: View {
    let prompt: String
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Prompt", accent: .tronInfo, tint: tint) {
            Text(prompt)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - WebFetch Answer Section

@available(iOS 26.0, *)
struct WebFetchAnswerSection: View {
    let answer: String
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Answer")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: answer, accent: .tronInfo)
            }

            VStack(alignment: .leading, spacing: 8) {
                let blocks = MarkdownBlockParser.parse(answer)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, textColor: tint.body)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .sectionFill(.tronInfo)
        }
    }
}

// MARK: - WebFetch Raw HTTP Info Section

@available(iOS 26.0, *)
struct WebFetchRawHttpInfoSection: View {
    let method: String
    let httpStatus: Int?
    let tint: TintedColors

    var body: some View {
        ToolDetailSection(title: "Request", accent: .tronInfo, tint: tint) {
            HStack(spacing: 12) {
                Text(method)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(methodColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                if let status = httpStatus {
                    Text("→ \(status)")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(statusColor(status))
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var methodColor: Color {
        switch method {
        case "POST": return .tronInfo
        case "PUT", "PATCH": return .tronAmber
        case "DELETE": return .tronError
        default: return .tronInfo
        }
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .tronEmerald
        case 300..<400: return .tronAmber
        default: return .tronError
        }
    }
}

// MARK: - WebFetch Raw Response Body Section

@available(iOS 26.0, *)
struct WebFetchRawResponseBodySection: View {
    let answer: String
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Response")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ToolCopyButton(content: answer, accent: .tronInfo)
            }

            Text(answer)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .sectionFill(.tronInfo)
        }
    }
}

// MARK: - WebFetch Streaming Answer Section

@available(iOS 26.0, *)
struct WebFetchStreamingAnswerSection: View {
    let answer: String
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Answer")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                ProgressView()
                    .scaleEffect(0.6)
                    .tint(.tronInfo)
            }

            VStack(alignment: .leading, spacing: 8) {
                let blocks = MarkdownBlockParser.parse(answer)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, textColor: tint.body)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .sectionFill(.tronInfo)
        }
    }
}
