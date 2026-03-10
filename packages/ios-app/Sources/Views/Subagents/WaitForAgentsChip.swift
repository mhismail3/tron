import SwiftUI

// MARK: - WaitForAgents Chip

/// In-chat chip for WaitForAgents tool calls.
/// Shows waiting status with agent count, then completion results.
/// Uses teal tint to distinguish from SubagentChip (emerald/amber) and QueryAgentChip (indigo).
struct WaitForAgentsChip: View {
    let data: WaitForAgentsChipData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(data.status.color)
                    .lineLimit(1)

                if data.agentCount > 1 {
                    Text("×\(data.agentCount)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(data.status.color.opacity(0.7))
                }

                if let duration = data.formattedDuration {
                    Text(duration)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(data.status.color.opacity(0.7))
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(data.status.color.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chipStyle(data.status.color)
        .chipAccessibility(tool: "Wait For Agents", status: data.status.label)
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
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .timedOut:
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronAmber)
        case .error:
            Image(systemName: data.status.iconName)
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
}
