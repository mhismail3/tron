import SwiftUI

// MARK: - WaitForAgents Chip

/// In-chat chip for WaitForAgents tool calls.
/// Shows waiting status with agent count, then completion results.
/// Uses teal tint to distinguish from SubagentChip (emerald/amber) and QueryAgentChip (indigo).
@available(iOS 26.0, *)
struct WaitForAgentsChip: View {
    let data: WaitForAgentsChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                // Agent count badge
                if data.agentCount > 1 {
                    Text("×\(data.agentCount)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(tintColor.opacity(0.35)).interactive(),
            in: .capsule
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .waiting:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronTeal)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .timedOut:
            Image(systemName: "clock.badge.exclamationmark")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronAmber)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .waiting:
            return data.agentCount > 1
                ? "Waiting for agents…"
                : "Waiting for agent…"
        case .completed:
            return data.agentCount > 1
                ? "Agents completed"
                : "Agent completed"
        case .timedOut:
            return "Wait timed out"
        case .error:
            return "Wait failed"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .waiting: return .tronTeal
        case .completed: return .tronTeal
        case .timedOut: return .tronAmber
        case .error: return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .waiting: return .tronTeal
        case .completed: return .tronTeal
        case .timedOut: return .tronAmber
        case .error: return .tronError
        }
    }
}

// MARK: - Fallback for iOS < 26

struct WaitForAgentsChipFallback: View {
    let data: WaitForAgentsChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                if data.agentCount > 1 {
                    Text("×\(data.agentCount)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .chipFill(tintColor)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .waiting:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronTeal)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .timedOut:
            Image(systemName: "clock.badge.exclamationmark")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronAmber)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .waiting:
            return data.agentCount > 1 ? "Waiting for agents…" : "Waiting for agent…"
        case .completed:
            return data.agentCount > 1 ? "Agents completed" : "Agent completed"
        case .timedOut: return "Wait timed out"
        case .error: return "Wait failed"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .waiting: return .tronTeal
        case .completed: return .tronTeal
        case .timedOut: return .tronAmber
        case .error: return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .waiting: return .tronTeal
        case .completed: return .tronTeal
        case .timedOut: return .tronAmber
        case .error: return .tronError
        }
    }
}
