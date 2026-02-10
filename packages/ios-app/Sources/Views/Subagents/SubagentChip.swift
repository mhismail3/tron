import SwiftUI

// MARK: - Subagent Chip

/// In-chat chip for spawned subagents
/// Shows real-time status updates: running (with turn count) → completed/failed
/// Tappable to open detail sheet with full output
@available(iOS 26.0, *)
struct SubagentChip: View {
    let data: SubagentToolData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Status icon
                statusIcon

                // Task preview
                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                // Turn count badge (while running)
                if data.status == .running {
                    Text("(T\(data.currentTurn))")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Duration badge (when completed)
                if let duration = data.formattedDuration, data.status == .completed || data.status == .failed {
                    Text("(\(duration))")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Chevron for tappable action
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
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronAmber)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .running:
            return "Agent running"
        case .completed:
            return "Agent completed"
        case .failed:
            return "Agent failed"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .running:
            return .tronAmber
        case .completed:
            return .tronSuccess
        case .failed:
            return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .running:
            return .tronAmber
        case .completed:
            return .tronSuccess
        case .failed:
            return .tronError
        }
    }
}

// MARK: - Fallback for iOS < 26

/// Fallback chip without glass effect for older iOS versions
struct SubagentChipFallback: View {
    let data: SubagentToolData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Status icon
                statusIcon

                // Task preview
                Text(statusText)
                    .font(TronTypography.filePath)
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                // Turn count badge (while running)
                if data.status == .running {
                    Text("(T\(data.currentTurn))")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Duration badge (when completed)
                if let duration = data.formattedDuration, data.status == .completed || data.status == .failed {
                    Text("(\(duration))")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Chevron
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
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronAmber)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .running: return "Agent running"
        case .completed: return "Agent completed"
        case .failed: return "Agent failed"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .running: return .tronAmber
        case .completed: return .tronSuccess
        case .failed: return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .running: return .tronAmber
        case .completed: return .tronSuccess
        case .failed: return .tronError
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
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
