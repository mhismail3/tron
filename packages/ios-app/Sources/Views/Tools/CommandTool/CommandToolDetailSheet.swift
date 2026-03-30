import SwiftUI

// MARK: - CommandTool Detail Sheet (iOS 26)

/// Sheet view displaying command tool details
/// Shows tool icon, name, arguments, status, and result using existing result viewers
@available(iOS 26.0, *)
struct CommandToolDetailSheet: View {
    let data: CommandToolChipData
    var onOpenURL: ((URL) -> Void)?
    @Environment(\.dismiss) private var dismiss

    /// Parsed URL for tools that provide a URL to open
    private var parsedURL: URL? {
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                contentView
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let url = parsedURL, let onOpenURL {
                        Button {
                            dismiss()
                            onOpenURL(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "safari")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                Text("Open")
                            }
                        }
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(data.iconColor)
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: data.icon)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(data.iconColor)
                        Text(data.displayName)
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(data.iconColor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(data.iconColor)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(data.iconColor)
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // Status & Duration Section
                CommandToolStatusSection(data: data)

                // Command/Arguments Section
                CommandToolArgumentsSection(data: data)

                // Result Section
                if let result = data.result, !result.isEmpty {
                    CommandToolResultSection(data: data, result: result)
                } else if data.status == .running {
                    if let output = data.streamingOutput, !output.isEmpty {
                        CommandToolStreamingResultSection(data: data, output: output)
                    } else {
                        CommandToolRunningSection()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("CommandTool Detail - Read") {
    CommandToolDetailSheet(
        data: CommandToolChipData(
            id: "call_1",
            toolName: "Read",
            normalizedName: "read",
            icon: "doc.text",
            iconColor: .tronEmerald,
            displayName: "Read",
            summary: "example.swift",
            status: .success,
            durationMs: 25,
            arguments: "{\"file_path\": \"/Users/test/example.swift\"}",
            result: "import Foundation\n\nstruct Example {\n    let name: String\n    var value: Int\n}\n",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("CommandTool Detail - Bash") {
    CommandToolDetailSheet(
        data: CommandToolChipData(
            id: "call_2",
            toolName: "Bash",
            normalizedName: "bash",
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summary: "git status --short",
            status: .success,
            durationMs: 45,
            arguments: "{\"command\": \"git status --short\"}",
            result: "M  README.md\nA  src/new-file.ts\n?? temp/",
            isResultTruncated: false
        )
    )
}
#endif
