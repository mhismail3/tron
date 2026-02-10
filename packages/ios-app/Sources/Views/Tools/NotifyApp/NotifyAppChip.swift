import SwiftUI

// MARK: - NotifyApp Chip (iOS 26)

/// Compact chip for NotifyApp tool calls
/// Shows "Notified User" with status indicator
/// Tappable to open NotifyAppDetailSheet
@available(iOS 26.0, *)
struct NotifyAppChip: View {
    let data: NotifyAppChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text("Notified User")
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
        case .sending:
            ProgressView()
                .scaleEffect(0.7)
                .tint(.tronAmber)
        case .sent:
            Image(systemName: "bell.badge.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "bell.slash.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .sending: .tronAmber
        case .sent: .tronSuccess
        case .failed: .tronError
        }
    }
}

// MARK: - NotifyApp Chip Fallback (iOS < 26)

/// Fallback chip without glass effect for older iOS versions
struct NotifyAppChipFallback: View {
    let data: NotifyAppChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text("Notified User")
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
        case .sending:
            ProgressView()
                .scaleEffect(0.7)
                .tint(.tronAmber)
        case .sent:
            Image(systemName: "bell.badge.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "bell.slash.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .sending: .tronAmber
        case .sent: .tronSuccess
        case .failed: .tronError
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("NotifyApp Chip States") {
    VStack(spacing: 16) {
        // Sending
        NotifyAppChip(
            data: NotifyAppChipData(
                toolCallId: "call_1",
                title: "Build Complete",
                body: "All tests passed",
                sheetContent: nil,
                status: .sending
            ),
            onTap: { }
        )

        // Sent
        NotifyAppChip(
            data: NotifyAppChipData(
                toolCallId: "call_2",
                title: "Build Complete",
                body: "All tests passed",
                sheetContent: "## Build Summary\n- 47 tests passed\n- Coverage: 85%",
                status: .sent,
                successCount: 1
            ),
            onTap: { }
        )

        // Failed
        NotifyAppChip(
            data: NotifyAppChipData(
                toolCallId: "call_3",
                title: "Build Complete",
                body: "All tests passed",
                sheetContent: nil,
                status: .failed,
                errorMessage: "No devices registered"
            ),
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
