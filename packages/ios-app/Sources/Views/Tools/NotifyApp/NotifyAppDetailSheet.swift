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
            ZStack {
                contentView
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tronEmerald)
                        Text("Notification")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
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
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
        .preferredColorScheme(.dark)
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Notification Header Section
                notificationHeaderSection

                // Sheet Content Section (markdown)
                if let sheetContent = data.sheetContent, !sheetContent.isEmpty {
                    sheetContentSection(sheetContent)
                }

                // Delivery Status Section
                if data.status == .sent || data.status == .failed {
                    deliveryStatusSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var notificationHeaderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            Text(data.title)
                .font(TronTypography.mono(size: TronTypography.sizeLargeTitle, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)

            // Body
            Text(data.body)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                .foregroundStyle(.tronTextSecondary)
        }
    }

    @ViewBuilder
    private func sheetContentSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronSlate)
                Text("DETAILS")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
            }

            // Markdown content
            Text(LocalizedStringKey(content))
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var deliveryStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: data.status == .sent ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(data.status == .sent ? .tronSuccess : .tronError)
                Text("DELIVERY STATUS")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
            }

            // Status message
            HStack(spacing: 8) {
                if data.status == .sent {
                    if let count = data.successCount {
                        Text("Delivered to \(count) device\(count == 1 ? "" : "s")")
                    } else {
                        Text("Delivered successfully")
                    }
                } else {
                    Text(data.errorMessage ?? "Failed to deliver notification")
                }
            }
            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
            .foregroundStyle(data.status == .sent ? .tronSuccess : .tronError)
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
                    // Title
                    Text(data.title)
                        .font(TronTypography.mono(size: TronTypography.sizeLargeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)

                    // Body
                    Text(data.body)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .regular))
                        .foregroundStyle(.tronTextSecondary)

                    // Sheet content (markdown)
                    if let sheetContent = data.sheetContent, !sheetContent.isEmpty {
                        Divider()
                        Text(LocalizedStringKey(sheetContent))
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }

                    // Delivery status
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
            .background(Color.black)
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
