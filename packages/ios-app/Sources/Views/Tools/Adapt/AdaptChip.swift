import SwiftUI

// MARK: - Adapt Chip (iOS 26)

/// Compact chip for Adapt (self-deployment) tool calls
/// Shows action + status with appropriate icon
/// Tappable to open AdaptDetailSheet
@available(iOS 26.0, *)
struct AdaptChip: View {
    let data: AdaptChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(displayText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(statusColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(statusColor.opacity(0.35)).interactive(),
            in: .capsule
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .running:
            ProgressView()
                .scaleEffect(0.7)
                .tint(.tronAmber)
        case .success:
            Image(systemName: successIcon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var successIcon: String {
        switch data.action {
        case .deploy: "arrow.up.circle.fill"
        case .status: "info.circle.fill"
        case .rollback: "arrow.uturn.backward.circle.fill"
        }
    }

    private var displayText: String {
        switch (data.action, data.status) {
        case (.deploy, .running): "Deploying..."
        case (.deploy, .success): "Deploy Initiated"
        case (.deploy, .failed): "Deploy Failed"
        case (.status, .running): "Checking Status..."
        case (.status, .success): "Deployment Status"
        case (.status, .failed): "Status Error"
        case (.rollback, .running): "Rolling Back..."
        case (.rollback, .success): "Rollback Initiated"
        case (.rollback, .failed): "Rollback Failed"
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

// MARK: - Adapt Chip Fallback (iOS < 26)

/// Fallback chip without glass effect for older iOS versions
struct AdaptChipFallback: View {
    let data: AdaptChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(displayText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(statusColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .chipFill(statusColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .running:
            ProgressView()
                .scaleEffect(0.7)
                .tint(.tronAmber)
        case .success:
            Image(systemName: successIcon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var successIcon: String {
        switch data.action {
        case .deploy: "arrow.up.circle.fill"
        case .status: "info.circle.fill"
        case .rollback: "arrow.uturn.backward.circle.fill"
        }
    }

    private var displayText: String {
        switch (data.action, data.status) {
        case (.deploy, .running): "Deploying..."
        case (.deploy, .success): "Deploy Initiated"
        case (.deploy, .failed): "Deploy Failed"
        case (.status, .running): "Checking Status..."
        case (.status, .success): "Deployment Status"
        case (.status, .failed): "Status Error"
        case (.rollback, .running): "Rolling Back..."
        case (.rollback, .success): "Rollback Initiated"
        case (.rollback, .failed): "Rollback Failed"
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
#Preview("Adapt Chip States") {
    VStack(spacing: 16) {
        // Deploy running
        AdaptChip(
            data: AdaptChipData(
                toolCallId: "call_1",
                action: .deploy,
                status: .running,
                isError: false
            ),
            onTap: { }
        )

        // Deploy success
        AdaptChip(
            data: AdaptChipData(
                toolCallId: "call_2",
                action: .deploy,
                status: .success,
                resultContent: "Build and tests passed. Deployment swap starts in 3 seconds.",
                isError: false
            ),
            onTap: { }
        )

        // Deploy failed
        AdaptChip(
            data: AdaptChipData(
                toolCallId: "call_3",
                action: .deploy,
                status: .failed,
                resultContent: "Build/test failed:\nFAIL src/foo.test.ts",
                isError: true
            ),
            onTap: { }
        )

        // Status check
        AdaptChip(
            data: AdaptChipData(
                toolCallId: "call_4",
                action: .status,
                status: .success,
                resultContent: "Last deployment:\n  Status: success\n  Commit: abc1234",
                isError: false
            ),
            onTap: { }
        )

        // Rollback initiated
        AdaptChip(
            data: AdaptChipData(
                toolCallId: "call_5",
                action: .rollback,
                status: .success,
                resultContent: "Rollback initiated. The server will restart in ~3 seconds.",
                isError: false
            ),
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
