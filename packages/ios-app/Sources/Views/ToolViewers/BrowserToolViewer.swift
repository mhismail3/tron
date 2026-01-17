import SwiftUI

// MARK: - Browser Result Viewer

struct BrowserResultViewer: View {
    let action: String
    let result: String
    @Binding var isExpanded: Bool

    private var displayText: String {
        if isExpanded || result.count <= 500 {
            return result
        }
        return String(result.prefix(500)) + "..."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(displayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if result.count > 500 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.system(size: 11, design: .monospaced))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.tronTextMuted)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(Color.tronSurface)
                }
            }
        }
    }
}

// MARK: - Open Browser Result Viewer
// Shows browser open action results

struct OpenBrowserResultViewer: View {
    let url: String
    let result: String
    @Binding var isExpanded: Bool

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
                    .font(.system(size: 14))
                    .foregroundStyle(isSuccess ? .tronSuccess : .tronError)

                VStack(alignment: .leading, spacing: 2) {
                    // Main message
                    Text(displayInfo.message)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronTextSecondary)

                    // URL or detail
                    if let detail = displayInfo.detail {
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.blue)
                            .lineLimit(isExpanded ? nil : 1)
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

                Text(isExpanded ? displayResult : String(displayResult.prefix(200)) + (displayResult.count > 200 ? "..." : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if displayResult.count > 200 {
                    Button {
                        withAnimation(.tronFast) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text(isExpanded ? "Show less" : "Show more")
                                .font(.system(size: 10, design: .monospaced))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.tronTextMuted)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Color.tronSurface)
                    }
                }
            }
        }
    }
}
