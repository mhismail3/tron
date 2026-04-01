import SwiftUI

// MARK: - NotifyApp Detail Sheet (iOS 26)

/// Sheet view displaying notification details
/// Shows title, body, optional sheet content (markdown), and delivery status
@available(iOS 26.0, *)
struct NotifyAppDetailSheet: View {
    let data: NotifyAppChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronEmerald, colorScheme: colorScheme)
    }

    private var statusToolStatus: CommandToolStatus {
        switch data.status {
        case .sending: .running
        case .sent: .success
        case .failed: .error
        }
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Notification",
            iconName: "bell.badge.fill",
            accent: .tronEmerald
        ) {
            contentView
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ToolStatusRow(status: statusToolStatus, durationMs: nil) {
                    if let count = data.successCount, data.status == .sent {
                        ToolInfoPill(
                            icon: "iphone.gen3",
                            label: "\(count) device\(count == 1 ? "" : "s")",
                            color: .tronSuccess
                        )
                    }
                }
                .sheetSection()

                notificationSection
                    .sheetSection()

                if let sheetContent = data.sheetContent, !sheetContent.isEmpty {
                    sheetContentSection(sheetContent)
                        .sheetSection()
                }

                if data.status == .failed {
                    errorSection
                        .sheetSection()
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Sections

    private var notificationSection: some View {
        ToolDetailSection(title: "Message", accent: .tronEmerald, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                Text(data.title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(tint.body)

                Text(data.body)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(tint.secondary)
            }
        }
    }

    @ViewBuilder
    private func sheetContentSection(_ content: String) -> some View {
        ToolDetailSection(title: "Details", accent: .tronEmerald, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                let blocks = MarkdownBlockParser.parse(content)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, textColor: tint.body)
                }
            }
            .textSelection(.enabled)
        }
    }

    private var errorSection: some View {
        ToolDetailSection(title: "Error", accent: .tronError, tint: tint) {
            Text(data.errorMessage ?? "Failed to deliver notification")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronError)
        }
    }
}

// MARK: - NotifyApp Detail Sheet Fallback (iOS < 26)

/// Fallback sheet for older iOS versions
struct NotifyAppDetailSheetFallback: View {
    let data: NotifyAppChipData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(data.title)
                        .font(TronTypography.mono(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)

                    Text(data.body)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                        .foregroundStyle(.tronTextSecondary)

                    if let sheetContent = data.sheetContent, !sheetContent.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            let blocks = MarkdownBlockParser.parse(sheetContent)
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                MarkdownBlockView(block: block, textColor: .tronTextSecondary)
                            }
                        }
                        .textSelection(.enabled)
                    }

                    if data.status == .sent || data.status == .failed {
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: data.status == .sent ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(data.status == .sent ? .green : .red)
                            if data.status == .sent {
                                if let count = data.successCount {
                                    Text("Delivered to \(count) device\(count == 1 ? "" : "s")")
                                } else {
                                    Text("Delivered")
                                }
                            } else {
                                Text(data.errorMessage ?? "Failed to deliver")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Notification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("NotifyApp Detail Sheet") {
    NotifyAppDetailSheet(
        data: NotifyAppChipData(
            toolCallId: "call_1",
            title: "Build Complete",
            body: "All 47 tests passed successfully",
            sheetContent: """
            ## Build Summary

            - **Tests:** 47 passed, 0 failed
            - **Coverage:** 85.2%
            - **Build time:** 12.3s

            ### Key Changes
            1. Added new authentication module
            2. Fixed memory leak in image processing
            3. Improved error handling in API client
            """,
            status: .sent,
            successCount: 2
        )
    )
}
#endif
