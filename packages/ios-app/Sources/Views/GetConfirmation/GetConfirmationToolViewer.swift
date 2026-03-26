import SwiftUI

// MARK: - GetConfirmation Tool Viewer

/// In-chat viewer for GetConfirmation tool calls.
/// Compact chip style matching AskUserQuestionToolViewer — glassy capsule with status colors.
/// Uses async model: pending -> approved/denied or superseded.
@available(iOS 26.0, *)
struct GetConfirmationToolViewer: View {
    let data: GetConfirmationToolData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(statusText)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                // Risk level badge (not during generating)
                if data.status != .generating {
                    riskBadge
                }

                // Chevron for tappable states
                if data.status != .superseded && data.status != .generating {
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(tintColor.opacity(0.35)),
                        in: .capsule
                    )
            }
            .overlay(
                Capsule()
                    .strokeBorder(tintColor.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(data.status == .superseded || data.status == .generating)
        .opacity(data.status == .superseded ? 0.6 : 1.0)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .generating:
            ProgressView()
                .controlSize(.small)
                .tint(.orange)
        case .pending:
            Image(systemName: "checkmark.shield")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.orange)
        case .approved:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        case .superseded:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
    }

    private var statusText: String {
        switch data.status {
        case .generating:
            return "Preparing confirmation\u{2026}"
        case .pending:
            return "Confirm action"
        case .approved:
            return "Approved"
        case .denied:
            return "Denied"
        case .superseded:
            return "Skipped"
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
        case .medium: return .orange
        case .high: return .tronError
        }
    }

    private var textColor: Color {
        switch data.status {
        case .generating, .pending: return .orange
        case .approved: return .tronSuccess
        case .denied: return .tronError
        case .superseded: return .tronTextMuted
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .generating, .pending: return .orange
        case .approved: return .tronSuccess
        case .denied: return .tronError
        case .superseded: return .tronTextMuted
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("All States") {
    VStack(spacing: 16) {
        GetConfirmationToolViewer(
            data: GetConfirmationToolData(
                toolCallId: "call_1",
                params: GetConfirmationParams(
                    action: "Install ffmpeg via brew",
                    reason: "Needed for video processing",
                    riskLevel: .low
                ),
                status: .pending
            ),
            onTap: { }
        )

        GetConfirmationToolViewer(
            data: GetConfirmationToolData(
                toolCallId: "call_2",
                params: GetConfirmationParams(
                    action: "Deploy to production",
                    reason: "Release v2.0",
                    riskLevel: .high
                ),
                status: .pending
            ),
            onTap: { }
        )

        GetConfirmationToolViewer(
            data: GetConfirmationToolData(
                toolCallId: "call_3",
                params: GetConfirmationParams(
                    action: "Install ffmpeg",
                    reason: "Needed",
                    riskLevel: .low
                ),
                status: .approved
            ),
            onTap: { }
        )

        GetConfirmationToolViewer(
            data: GetConfirmationToolData(
                toolCallId: "call_4",
                params: GetConfirmationParams(
                    action: "Delete ~/project/",
                    reason: "Cleanup",
                    riskLevel: .high
                ),
                status: .denied
            ),
            onTap: { }
        )

        GetConfirmationToolViewer(
            data: GetConfirmationToolData(
                toolCallId: "call_5",
                params: GetConfirmationParams(
                    action: "Modify config",
                    reason: "Settings",
                    riskLevel: .medium
                ),
                status: .superseded
            ),
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
