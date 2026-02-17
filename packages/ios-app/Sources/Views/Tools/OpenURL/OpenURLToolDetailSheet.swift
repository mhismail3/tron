import SwiftUI
import SafariServices

// MARK: - OpenURL Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for the OpenURL tool.
/// Shows the URL with domain info, a tappable link for external Safari,
/// and an "Open" button that presents an in-app SFSafariViewController
/// as a nested sheet over this detail sheet.
@available(iOS 26.0, *)
struct OpenURLToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var showInAppBrowser = false

    private var tint: TintedColors {
        TintedColors(accent: .blue, colorScheme: colorScheme)
    }

    private var url: String {
        ToolArgumentParser.url(from: data.arguments)
    }

    private var parsedURL: URL? {
        URL(string: url)
    }

    private var domain: String {
        ToolArgumentParser.extractDomain(from: url)
    }

    private var scheme: String {
        parsedURL?.scheme?.uppercased() ?? "URL"
    }

    private var isSuccess: Bool {
        data.status == .success && data.result?.lowercased().contains("opening") == true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                contentBody
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if parsedURL != nil {
                        Button {
                            showInAppBrowser = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                    .font(.system(size: 13))
                                Text("Open")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            }
                            .foregroundStyle(.blue)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                            .font(.system(size: 14))
                            .foregroundStyle(.blue)
                        Text("Open URL")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.blue)
                }
            }
            .sheet(isPresented: $showInAppBrowser) {
                if let parsedURL {
                    SafariView(url: parsedURL)
                        .ignoresSafeArea()
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.blue)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    urlSection
                        .padding(.horizontal)
                    statusRow
                        .padding(.horizontal)

                    switch data.status {
                    case .success:
                        if let result = data.result, OpenURLDetailParser.isError(result) {
                            errorSection(OpenURLDetailParser.extractError(from: result))
                                .padding(.horizontal)
                        } else {
                            resultSection
                                .padding(.horizontal)
                        }
                    case .error:
                        if let result = data.result {
                            errorSection(OpenURLDetailParser.extractError(from: result))
                                .padding(.horizontal)
                        }
                    case .running:
                        runningSection
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
                .frame(width: geometry.size.width)
            }
        }
    }

    // MARK: - URL Section

    private var urlSection: some View {
        ToolDetailSection(title: "URL", accent: .blue, tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue)

                    Text(domain)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(tint.name)
                        .lineLimit(1)

                    Spacer()

                    Text(scheme)
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.2)), in: Capsule())
                        }
                }

                if !url.isEmpty {
                    if let parsedURL {
                        Button {
                            openURL(parsedURL)
                        } label: {
                            HStack(spacing: 4) {
                                Text(url)
                                    .font(TronTypography.codeCaption)
                                    .foregroundStyle(.blue)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.blue.opacity(0.6))
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(url)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(tint.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: data.status)

                if let ms = data.durationMs {
                    ToolDurationBadge(durationMs: ms)
                }
            }
        }
    }

    // MARK: - Result Section

    private var resultSection: some View {
        ToolDetailSection(title: "Result", accent: .blue, tint: tint) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.tronEmerald)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Opened in Safari")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(tint.body)

                    Text(domain)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(tint.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Error Section

    private func errorSection(_ errorMessage: String) -> some View {
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
        let errorInfo = OpenURLDetailParser.classifyError(errorMessage)

        return ToolDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: errorInfo.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(.tronError)

                    Text(errorInfo.title)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronError)
                }

                if !url.isEmpty {
                    Text(url)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(errorTint.secondary)
                        .textSelection(.enabled)
                }

                if let code = errorInfo.code {
                    ToolInfoPill(icon: "exclamationmark.triangle", label: code, color: .tronError)
                }

                Text(errorInfo.suggestion)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(errorTint.subtle)
            }
        }
    }

    // MARK: - Running Section

    private var runningSection: some View {
        ToolDetailSection(title: "Result", accent: .blue, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.blue)
                    .scaleEffect(1.1)
                Text("Opening URL...")
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}

// MARK: - OpenURL Detail Parser

enum OpenURLDetailParser {

    static func extractError(from result: String) -> String {
        if let match = result.firstMatch(of: /Error:\s*(.+)/) {
            return String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func isError(_ result: String) -> Bool {
        let lower = result.lowercased()
        return lower.contains("invalid") || lower.contains("error") ||
               lower.contains("failed") || lower.contains("missing required")
    }

    static func classifyError(_ message: String) -> (icon: String, title: String, code: String?, suggestion: String) {
        let lower = message.lowercased()

        if lower.contains("invalid url format") {
            return ("link.badge.plus", "Invalid URL", "INVALID_FORMAT",
                    "The URL format is not valid. Check for typos or missing components.")
        }
        if lower.contains("invalid url scheme") || lower.contains("invalid scheme") {
            return ("lock.slash", "Invalid Scheme", "INVALID_SCHEME",
                    "Only http:// and https:// URLs are supported.")
        }
        if lower.contains("missing required") || lower.contains("missing") && lower.contains("url") {
            return ("questionmark.circle", "Missing URL", "MISSING_PARAM",
                    "No URL was provided. The url parameter is required.")
        }
        if lower.contains("failed to open") {
            return ("xmark.circle", "Failed to Open", nil,
                    "The URL could not be opened. The browser may not be available.")
        }

        return ("exclamationmark.triangle.fill", "Open Failed", nil,
                "An error occurred while trying to open the URL.")
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("OpenURL - Success") {
    OpenURLToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ou1",
            toolName: "OpenURL",
            normalizedName: "openurl",
            icon: "safari",
            iconColor: .blue,
            displayName: "Open URL",
            summary: "docs.anthropic.com",
            status: .success,
            durationMs: 50,
            arguments: "{\"url\": \"https://docs.anthropic.com/en/docs/about-claude/models\"}",
            result: "Opening https://docs.anthropic.com/en/docs/about-claude/models in Safari",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("OpenURL - Invalid URL") {
    OpenURLToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ou2",
            toolName: "OpenURL",
            normalizedName: "openurl",
            icon: "safari",
            iconColor: .blue,
            displayName: "Open URL",
            summary: "ftp://x.com",
            status: .success,
            durationMs: 5,
            arguments: "{\"url\": \"ftp://x.com\"}",
            result: "Invalid URL scheme: \"ftp\". Only http:// and https:// URLs are allowed.",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("OpenURL - Missing URL") {
    OpenURLToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ou3",
            toolName: "OpenURL",
            normalizedName: "openurl",
            icon: "safari",
            iconColor: .blue,
            displayName: "Open URL",
            summary: "",
            status: .error,
            durationMs: 2,
            arguments: "{}",
            result: "Missing required parameter: url",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("OpenURL - Running") {
    OpenURLToolDetailSheet(
        data: CommandToolChipData(
            id: "call_ou4",
            toolName: "OpenURL",
            normalizedName: "openurl",
            icon: "safari",
            iconColor: .blue,
            displayName: "Open URL",
            summary: "github.com",
            status: .running,
            durationMs: nil,
            arguments: "{\"url\": \"https://github.com/anthropics/claude-code\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}
#endif
