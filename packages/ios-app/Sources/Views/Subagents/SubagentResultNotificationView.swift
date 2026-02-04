import SwiftUI

/// Notification chip shown when a subagent completes while the parent agent is idle.
/// Tapping opens the subagent detail sheet where results can be sent to the agent.
@available(iOS 26.0, *)
struct SubagentResultNotificationView: View {
    let subagentSessionId: String
    let taskPreview: String
    let success: Bool
    var onTap: (() -> Void)?

    private var accentColor: Color {
        success ? .tronSuccess : .tronError
    }

    private var iconName: String {
        success ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var titleText: String {
        success ? "Agent results ready" : "Agent failed"
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 10) {
                // Status indicator
                Image(systemName: iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(taskPreview)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer()

                // Tap hint
                HStack(spacing: 4) {
                    Text("Review")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                }
                .foregroundStyle(accentColor.opacity(0.8))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(accentColor.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accentColor.opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
