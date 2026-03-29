import SwiftUI

// MARK: - Subagent Chip

/// In-chat chip for spawned subagents
/// Shows real-time status updates: running (with turn count) → completed/failed
/// Tappable to open detail sheet with full output
struct SubagentChip: View {
    let data: SubagentToolData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(data.status.label)
                    .font(TronTypography.filePath)
                    .foregroundStyle(data.status.color)
                    .lineLimit(1)

                if data.status == .running {
                    Text("(T\(data.currentTurn))")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(data.status.color.opacity(0.7))
                }

                if let duration = data.formattedDuration, data.status == .completed || data.status == .failed {
                    Text("(\(duration))")
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
        .chipAccessibility(tool: "Subagent", status: data.status.label)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronAmber)
        case .completed:
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Subagent States") {
    VStack(spacing: 16) {
        SubagentChip(
            data: SubagentToolData(
                toolCallId: "call_2",
                subagentSessionId: "sess_def456",
                task: "Analyze codebase structure",
                model: "claude-sonnet-4",
                status: .running,
                currentTurn: 3,
                resultSummary: nil,
                fullOutput: nil,
                duration: nil,
                error: nil,
                tokenUsage: nil
            ),
            onTap: { }
        )

        SubagentChip(
            data: SubagentToolData(
                toolCallId: "call_3",
                subagentSessionId: "sess_ghi789",
                task: "Fix the bug in authentication",
                model: "claude-sonnet-4",
                status: .completed,
                currentTurn: 5,
                resultSummary: "Fixed the authentication bug",
                fullOutput: "Full output here...",
                duration: 12500,
                error: nil,
                tokenUsage: nil
            ),
            onTap: { }
        )

        SubagentChip(
            data: SubagentToolData(
                toolCallId: "call_4",
                subagentSessionId: "sess_jkl012",
                task: "Deploy to production",
                model: "claude-sonnet-4",
                status: .failed,
                currentTurn: 2,
                resultSummary: nil,
                fullOutput: nil,
                duration: 3200,
                error: "Permission denied",
                tokenUsage: nil
            ),
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
