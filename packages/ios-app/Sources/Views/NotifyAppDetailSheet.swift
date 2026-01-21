import SwiftUI

// MARK: - NotifyApp Detail Sheet (iOS 26)

/// Sheet view displaying notification details
/// Shows title, body, optional sheet content (markdown), and delivery status
@available(iOS 26.0, *)
struct NotifyAppDetailSheet: View {
    let data: NotifyAppChipData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Notification title (header)
                    Text(data.title)
                        .font(TronTypography.mono(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)

                    // Notification body
                    Text(data.body)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                        .foregroundStyle(.tronTextPrimary)

                    // Sheet content (markdown)
                    if let sheetContent = data.sheetContent, !sheetContent.isEmpty {
                        Divider()
                            .background(Color.tronBorder)

                        // Render markdown content
                        Text(LocalizedStringKey(sheetContent))
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }

                    // Delivery status
                    if data.status == .sent || data.status == .failed {
                        Divider()
                            .background(Color.tronBorder)

                        deliveryStatusView
                    }
                }
                .padding()
            }
            .background(Color.tronBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(.tronEmerald)
                        Text("Notification")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        HStack(spacing: 8) {
            if data.status == .sent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tronSuccess)
                if let count = data.successCount {
                    Text("Delivered to \(count) device\(count == 1 ? "" : "s")")
                } else {
                    Text("Delivered")
                }
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tronError)
                Text(data.errorMessage ?? "Failed to deliver")
            }
        }
        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .regular))
        .foregroundStyle(.tronTextMuted)
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
                    // Notification title (header)
                    Text(data.title)
                        .font(TronTypography.mono(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.tronEmerald)

                    // Notification body
                    Text(data.body)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                        .foregroundStyle(.tronTextPrimary)

                    // Sheet content (markdown)
                    if let sheetContent = data.sheetContent, !sheetContent.isEmpty {
                        Divider()
                            .background(Color.tronBorder)

                        // Render markdown content
                        Text(LocalizedStringKey(sheetContent))
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }

                    // Delivery status
                    if data.status == .sent || data.status == .failed {
                        Divider()
                            .background(Color.tronBorder)

                        deliveryStatusView
                    }
                }
                .padding()
            }
            .background(Color.tronBackground)
            .navigationTitle("Notification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        HStack(spacing: 8) {
            if data.status == .sent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tronSuccess)
                if let count = data.successCount {
                    Text("Delivered to \(count) device\(count == 1 ? "" : "s")")
                } else {
                    Text("Delivered")
                }
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tronError)
                Text(data.errorMessage ?? "Failed to deliver")
            }
        }
        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .regular))
        .foregroundStyle(.tronTextMuted)
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
