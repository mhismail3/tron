import SwiftUI

// MARK: - NotifyApp Chip

/// Compact chip for NotifyApp tool calls
/// Shows "Notified User" with status indicator
/// Tappable to open NotifyAppDetailSheet
struct NotifyAppChip: View {
    let data: NotifyAppChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text("Notified User")
                    .font(TronTypography.filePath)
                    .foregroundStyle(data.status.color)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(data.status.color.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
            .animation(.smooth(duration: 0.3), value: data.status)
        }
        .buttonStyle(.plain)
        .chipStyle(data.status.color)
        .chipAccessibility(tool: "Notify", status: data.status.label)
    }

    @ViewBuilder
    private var statusIcon: some View {
        let iconSize = TronTypography.sizeBodySM
        switch data.status {
        case .sending:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: iconSize, height: iconSize)
                .tint(.tronAmber)
        case .sent:
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("NotifyApp Chip States") {
    VStack(spacing: 16) {
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
