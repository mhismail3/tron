import SwiftUI

// MARK: - Subagent Chip

/// In-chat chip for spawned subagents
/// Shows real-time status updates: spawning → running (with turn count) → completed/failed
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
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                // Turn count badge (while running)
                if data.status == .running || data.status == .spawning {
                    Text("(T\(data.currentTurn))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Duration badge (when completed)
                if let duration = data.formattedDuration, data.status == .completed || data.status == .failed {
                    Text("(\(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Chevron for tappable action
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.6))
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
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .spawning:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronEmerald)
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronEmerald)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .spawning:
            return "Spawning agent..."
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
        case .spawning, .running:
            return .tronEmerald
        case .completed:
            return .tronSuccess
        case .failed:
            return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .spawning, .running:
            return .tronEmerald
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
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                // Turn count badge (while running)
                if data.status == .running || data.status == .spawning {
                    Text("(T\(data.currentTurn))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Duration badge (when completed)
                if let duration = data.formattedDuration, data.status == .completed || data.status == .failed {
                    Text("(\(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(tintColor.opacity(0.15))
            )
            .overlay(
                Capsule()
                    .strokeBorder(tintColor.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .spawning, .running:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(.tronEmerald)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tronError)
        }
    }

    private var statusText: String {
        switch data.status {
        case .spawning: return "Spawning agent..."
        case .running: return "Agent running"
        case .completed: return "Agent completed"
        case .failed: return "Agent failed"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .spawning, .running: return .tronEmerald
        case .completed: return .tronSuccess
        case .failed: return .tronError
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .spawning, .running: return .tronEmerald
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
                toolCallId: "call_1",
                subagentSessionId: "sess_abc123",
                task: "Search for files matching pattern",
                model: "claude-sonnet-4",
                status: .spawning,
                currentTurn: 0,
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
