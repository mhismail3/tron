import SwiftUI

// MARK: - Browse The Web Tool Viewer
// Updated name: BrowseTheWebTool (was AgentWebBrowser)

struct BrowserToolViewer: View {
    let action: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(result)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Open URL Result Viewer
// Updated name: OpenURLTool (was OpenBrowser)

struct OpenURLResultViewer: View {
    let url: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    /// Unescape JSON escape sequences in strings
    private func unescape(_ str: String) -> String {
        str.replacingOccurrences(of: "\\/", with: "/")
           .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Unescaped URL for display
    private var displayUrl: String {
        unescape(url)
    }

    /// Unescaped result for display
    private var displayResult: String {
        unescape(result)
    }

    /// Parse the result to extract meaningful info
    private var displayInfo: (icon: String, message: String, detail: String?) {
        let lowercased = displayResult.lowercased()

        if lowercased.contains("opening") || lowercased.contains("opened") {
            return ("checkmark.circle.fill", "Opened in browser", displayUrl.isEmpty ? nil : displayUrl)
        } else if lowercased.contains("safari") {
            return ("safari.fill", "Opening in Safari", displayUrl.isEmpty ? nil : displayUrl)
        } else if lowercased.contains("chrome") {
            return ("globe", "Opening in Chrome", displayUrl.isEmpty ? nil : displayUrl)
        } else if lowercased.contains("error") || lowercased.contains("failed") {
            return ("xmark.circle.fill", "Failed to open", displayResult)
        } else {
            // Default: show the result as-is
            return ("safari", "Browser action", nil)
        }
    }

    private var isSuccess: Bool {
        let lowercased = displayResult.lowercased()
        return !lowercased.contains("error") && !lowercased.contains("failed")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Status icon
                Image(systemName: displayInfo.icon)
                    .font(TronTypography.messageBody)
                    .foregroundStyle(isSuccess ? .tronSuccess : .tronError)

                VStack(alignment: .leading, spacing: 2) {
                    // Main message
                    Text(displayInfo.message)
                        .font(TronTypography.filePath)
                        .foregroundStyle(.tronTextSecondary)

                    // URL or detail
                    if let detail = displayInfo.detail {
                        Text(detail)
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.blue)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Show full result if different from parsed display
            if !displayResult.isEmpty && displayResult != displayInfo.message && displayResult != displayInfo.detail {
                Rectangle()
                    .fill(Color.tronBorder.opacity(0.3))
                    .frame(height: 0.5)

                Text(displayResult)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }
}

