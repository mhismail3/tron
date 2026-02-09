import SwiftUI

// MARK: - Event Row

@available(iOS 26.0, *)
struct SubagentEventRow: View {
    let event: SubagentEventItem
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Event icon with optional spinner
            ZStack {
                eventIcon
                if event.isRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.4)
                        .tint(iconColor)
                }
            }
            .frame(width: 16, height: 16)

            // Event content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)

                    if event.isRunning {
                        Text("•")
                            .font(TronTypography.sans(size: TronTypography.sizeXS))
                            .foregroundStyle(iconColor)
                    }
                }

                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(TronTypography.mono(size: TronTypography.sizeBody2))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(6)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            // Timestamp (only show for completed events)
            if !event.isRunning {
                Text(formatTime(event.timestamp))
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextDisabled)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            if event.isRunning {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.08))
            }
        }
    }

    private var iconColor: Color {
        switch event.type {
        case .tool:
            return event.isRunning ? .tronAmber : .tronEmerald
        case .output:
            return accentColor
        case .thinking:
            return .tronPurple
        }
    }

    @ViewBuilder
    private var eventIcon: some View {
        switch event.type {
        case .tool:
            if event.isRunning {
                Image(systemName: "gearshape.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(.tronAmber)
            } else if event.title.contains("✗") {
                Image(systemName: "xmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(.tronError)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(.tronEmerald)
            }
        case .output:
            Image(systemName: "text.bubble.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                .foregroundStyle(accentColor)
        case .thinking:
            Image(systemName: "brain")
                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                .foregroundStyle(.tronPurple)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
