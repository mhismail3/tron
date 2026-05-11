import SwiftUI

// MARK: - Engine Approval Chip

/// In-chat viewer for engine-owned approval records.
/// Compact chip style matching AskUserQuestionToolViewer.
@available(iOS 26.0, *)
struct EngineApprovalChipView: View {
    let data: EngineApprovalToolData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(statusText)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                riskBadge

                // Chevron for tappable states
                if data.status != .failed {
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chipStyle(tintColor)
        .disabled(data.status == .failed)
        .opacity(data.status == .failed ? 0.75 : 1.0)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .pending:
            Image(systemName: "checkmark.shield")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronAmber)
        case .approved:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .pending:
            return "Confirm action"
        case .approved:
            return "Approved"
        case .denied:
            return "Denied"
        case .failed:
            return "Approval failed"
        }
    }

    @ViewBuilder
    private var riskBadge: some View {
        Text(data.params.riskLevel.rawValue.uppercased())
            .font(TronTypography.badge)
            .foregroundStyle(riskColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(riskColor.opacity(0.15))
            )
    }

    private var riskColor: Color {
        switch data.params.riskLevel {
        case .low: return .tronEmerald
        case .medium: return .tronAmber
        case .high: return .tronError
        }
    }

    private var textColor: Color {
        switch data.status {
        case .pending: return .tronAmber
        case .approved: return .tronSuccess
        case .denied, .failed: return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .pending: return .tronAmber
        case .approved: return .tronSuccess
        case .denied, .failed: return .tronError
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("All States") {
    VStack(spacing: 16) {
        EngineApprovalChipView(
            data: EngineApprovalToolData(
                toolCallId: "call_1",
                params: EngineApprovalParams(
                    action: "Install ffmpeg via brew",
                    reason: "Needed for video processing",
                    riskLevel: .low
                ),
                status: .pending
            ),
            onTap: { }
        )

        EngineApprovalChipView(
            data: EngineApprovalToolData(
                toolCallId: "call_2",
                params: EngineApprovalParams(
                    action: "Deploy to production",
                    reason: "Release v2.0",
                    riskLevel: .high
                ),
                status: .pending
            ),
            onTap: { }
        )

        EngineApprovalChipView(
            data: EngineApprovalToolData(
                toolCallId: "call_3",
                params: EngineApprovalParams(
                    action: "Install ffmpeg",
                    reason: "Needed",
                    riskLevel: .low
                ),
                status: .approved
            ),
            onTap: { }
        )

        EngineApprovalChipView(
            data: EngineApprovalToolData(
                toolCallId: "call_4",
                params: EngineApprovalParams(
                    action: "Delete ~/project/",
                    reason: "Cleanup",
                    riskLevel: .high
                ),
                status: .denied
            ),
            onTap: { }
        )

        EngineApprovalChipView(
            data: EngineApprovalToolData(
                toolCallId: "call_5",
                params: EngineApprovalParams(
                    action: "Modify config",
                    reason: "Settings",
                    riskLevel: .medium
                ),
                status: .failed
            ),
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
