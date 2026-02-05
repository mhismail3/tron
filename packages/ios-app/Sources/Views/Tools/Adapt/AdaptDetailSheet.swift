import SwiftUI

// MARK: - Adapt Detail Sheet (iOS 26)

/// Sheet view displaying deployment action details
/// Shows action type, status, and full result content
@available(iOS 26.0, *)
struct AdaptDetailSheet: View {
    let data: AdaptChipData
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
                        Image(systemName: actionIcon)
                            .font(.system(size: 14))
                            .foregroundStyle(.tronEmerald)
                        Text(actionTitle)
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
                // Status section
                statusSection

                // Result content section
                if let content = data.resultContent, !content.isEmpty {
                    resultSection(content)
                }

                // Reconnection info for deploy/rollback success
                if data.action != .status && data.status == .success {
                    reconnectionInfoSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status badge
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(statusColor.opacity(0.15))
            )
        }
    }

    @ViewBuilder
    private func resultSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronSlate)
                Text("OUTPUT")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
            }

            // Result content
            Text(content)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var reconnectionInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: "wifi.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronInfo)
                Text("WHAT HAPPENS NEXT")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                infoRow(icon: "clock", text: "Server restarts in ~3 seconds")
                infoRow(icon: "wifi.exclamationmark", text: "Brief disconnect (~15-20 seconds)")
                infoRow(icon: "arrow.clockwise", text: "App reconnects automatically")
                infoRow(icon: "checkmark.shield", text: "Auto-rollback if health check fails")
            }
        }
    }

    @ViewBuilder
    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.tronInfo)
                .frame(width: 16)
            Text(text)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                .foregroundStyle(.tronTextSecondary)
        }
    }

    // MARK: - Computed Properties

    private var actionIcon: String {
        switch data.action {
        case .deploy: "arrow.up.circle.fill"
        case .status: "info.circle.fill"
        case .rollback: "arrow.uturn.backward.circle.fill"
        }
    }

    private var actionTitle: String {
        switch data.action {
        case .deploy: "Deploy"
        case .status: "Deployment Status"
        case .rollback: "Rollback"
        }
    }

    private var statusIcon: String {
        switch data.status {
        case .running: "hourglass"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var statusText: String {
        switch (data.action, data.status) {
        case (.deploy, .running): "Building and testing..."
        case (.deploy, .success): "Build passed, swap initiated"
        case (.deploy, .failed): "Build or tests failed"
        case (.status, .running): "Checking deployment status..."
        case (.status, .success): "Status retrieved"
        case (.status, .failed): "Failed to read status"
        case (.rollback, .running): "Initiating rollback..."
        case (.rollback, .success): "Rollback initiated"
        case (.rollback, .failed): "Rollback failed"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .running: .tronAmber
        case .success: .tronSuccess
        case .failed: .tronError
        }
    }
}

// MARK: - Adapt Detail Sheet Fallback (iOS < 26)

/// Fallback sheet for older iOS versions
struct AdaptDetailSheetFallback: View {
    let data: AdaptChipData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status badge
                    HStack(spacing: 8) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                        Text(statusText)
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }

                    // Result content
                    if let content = data.resultContent, !content.isEmpty {
                        Divider()
                        Text(content)
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .regular))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }

                    // Reconnection info
                    if data.action != .status && data.status == .success {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Server will restart briefly. The app reconnects automatically.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .background(Color.black)
            .navigationTitle(actionTitle)
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

    private var actionTitle: String {
        switch data.action {
        case .deploy: "Deploy"
        case .status: "Deployment Status"
        case .rollback: "Rollback"
        }
    }

    private var statusIcon: String {
        switch data.status {
        case .running: "hourglass"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var statusText: String {
        switch (data.action, data.status) {
        case (.deploy, .running): "Building and testing..."
        case (.deploy, .success): "Build passed, swap initiated"
        case (.deploy, .failed): "Build or tests failed"
        case (.status, .running): "Checking deployment status..."
        case (.status, .success): "Status retrieved"
        case (.status, .failed): "Failed to read status"
        case (.rollback, .running): "Initiating rollback..."
        case (.rollback, .success): "Rollback initiated"
        case (.rollback, .failed): "Rollback failed"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .running: .tronAmber
        case .success: .tronSuccess
        case .failed: .tronError
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("Adapt Detail - Deploy Success") {
    AdaptDetailSheet(
        data: AdaptChipData(
            toolCallId: "call_1",
            action: .deploy,
            status: .success,
            resultContent: "Build and tests passed. Deployment swap starts in 3 seconds. The server will restart \u{2014} after reconnecting, use `Adapt` with action `status` to verify.",
            isError: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("Adapt Detail - Status") {
    AdaptDetailSheet(
        data: AdaptChipData(
            toolCallId: "call_2",
            action: .status,
            status: .success,
            resultContent: """
            Last deployment:
              Status:          success
              Timestamp:       2026-02-05T12:00:00Z
              Commit:          abc1234
              Previous commit: def5678
            """,
            isError: false
        )
    )
}
#endif
