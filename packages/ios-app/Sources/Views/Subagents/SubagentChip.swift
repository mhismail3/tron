import SwiftUI

// MARK: - Subagent Chip Variant

/// Which capability invocation produced this subagent chip. Controls the running-
/// state label and whether the target session id is surfaced so the
/// Wait chip is visually distinguishable from Spawn.
///
/// Both tools share the same `SubagentToolData` shape server-side, so
/// this flag is passed in by the call site (MessageBubble) rather
/// than carried on the data itself — the data is the ground truth
/// about the subagent's lifecycle, the variant is about which surface
/// rendered the chip.
enum SubagentChipVariant: Equatable, Sendable {
    /// Rendered for `spawn_subagent` — "Agent running / completed / failed".
    case spawn
    /// Rendered for `wait_for_subagent` — "Waiting for agent / Agent returned".
    /// Running state surfaces a short prefix of the target session id so
    /// the user can match it to the earlier Spawn chip.
    case wait
}

// MARK: - Subagent Chip

/// In-chat chip for spawned subagents
/// Shows real-time status updates: running (with turn count) → completed/failed
/// Tappable to open detail sheet with full output
struct SubagentChip: View {
    let data: SubagentToolData
    var variant: SubagentChipVariant = .spawn
    let onTap: () -> Void

    /// Label text that reflects the variant's semantics. Wait uses
    /// present-progressive "Waiting..." while running and a distinct
    /// "Agent returned" on completion so the user recognizes that this
    /// is a resumption event, not a new spawn.
    private var label: String {
        switch (variant, data.status) {
        case (.spawn, .running):    return "Agent running"
        case (.spawn, .completed):  return "Agent completed"
        case (.spawn, .failed):     return "Agent failed"
        case (.wait, .running):     return "Waiting for agent"
        case (.wait, .completed):   return "Agent returned"
        case (.wait, .failed):      return "Agent failed"
        }
    }

    /// Tiny uppercase kind badge — "SUB" (Spawn) or "WAIT". Keeps the
    /// two subagent variants visually distinct from a Bash-BG chip even
    /// when all three share a running spinner + amber color.
    var kindBadgeText: String {
        switch variant {
        case .spawn: return "SUB"
        case .wait:  return "WAIT"
        }
    }

    var kindBadgeAccessibilityLabel: String {
        switch variant {
        case .spawn: return "Subagent"
        case .wait:  return "Waiting for subagent"
        }
    }

    /// Short prefix of the target subagent session id. Only shown on
    /// the Wait variant — Spawn doesn't need it because the chip IS
    /// the origin of that id.
    private var targetIdBadge: String? {
        guard variant == .wait, !data.subagentSessionId.isEmpty else { return nil }
        // 6-char prefix matches the dashboard row and subagent sheet
        // truncation — user can cross-reference at a glance.
        let id = data.subagentSessionId
        let endIndex = id.index(id.startIndex, offsetBy: min(6, id.count))
        return String(id[..<endIndex])
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                statusIcon

                Text(label)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(data.status.color)
                    .lineLimit(1)

                Text(kindBadgeText)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .foregroundStyle(data.status.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(data.status.color.opacity(0.14))
                    .clipShape(Capsule())
                    .accessibilityLabel(kindBadgeAccessibilityLabel)

                if let targetIdBadge {
                    Text("#\(targetIdBadge)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(data.status.color.opacity(0.7))
                        .accessibilityLabel("Target subagent \(targetIdBadge)")
                }

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
        .chipAccessibility(tool: variant == .wait ? "Wait for agent" : "Subagent", status: label)
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
                invocationId: "call_2",
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
            variant: .spawn,
            onTap: { }
        )

        SubagentChip(
            data: SubagentToolData(
                invocationId: "call_wait_1",
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
            variant: .wait,
            onTap: { }
        )

        SubagentChip(
            data: SubagentToolData(
                invocationId: "call_3",
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
            variant: .spawn,
            onTap: { }
        )

        SubagentChip(
            data: SubagentToolData(
                invocationId: "call_wait_2",
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
            variant: .wait,
            onTap: { }
        )

        SubagentChip(
            data: SubagentToolData(
                invocationId: "call_4",
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
            variant: .spawn,
            onTap: { }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
