import SwiftUI

// MARK: - Plan Mode Notification Views

/// In-chat notification for when plan mode is entered
@available(iOS 26.0, *)
struct PlanModeEnteredView: View {
    let skillName: String
    let blockedTools: [String]

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.tronAmber)

            VStack(alignment: .leading, spacing: 2) {
                Text("Plan Mode Active")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tronAmber)

                Text("Read-only until plan is approved")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
            }

            Spacer()

            // Skill name badge
            Text(skillName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tronAmber)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.tronAmber.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(12)
        .background(Color.tronAmber.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.tronAmber.opacity(0.3), lineWidth: 1)
        )
    }
}

/// In-chat notification for when plan mode is exited
@available(iOS 26.0, *)
struct PlanModeExitedView: View {
    let reason: String
    let planPath: String?

    private var reasonIcon: String {
        switch reason {
        case "approved": return "checkmark.circle.fill"
        case "cancelled": return "xmark.circle.fill"
        case "timeout": return "clock.badge.xmark.fill"
        default: return "arrow.right.circle.fill"
        }
    }

    private var reasonColor: Color {
        switch reason {
        case "approved": return .tronSuccess
        case "cancelled": return .tronError
        case "timeout": return .tronWarning
        default: return .tronTextSecondary
        }
    }

    private var reasonText: String {
        switch reason {
        case "approved": return "Plan approved"
        case "cancelled": return "Plan cancelled"
        case "timeout": return "Plan timed out"
        default: return "Plan mode ended"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: reasonIcon)
                .font(.system(size: 18))
                .foregroundStyle(reasonColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(reasonText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(reasonColor)

                if reason == "approved", let path = planPath {
                    // Show truncated plan path
                    Text(truncatePath(path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(reasonColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(reasonColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func truncatePath(_ path: String) -> String {
        // Show just the filename from the path
        let components = path.split(separator: "/")
        if let filename = components.last {
            return String(filename)
        }
        return path
    }
}

/// Compact pill showing plan mode is active (for status bar)
@available(iOS 26.0, *)
struct PlanModePill: View {
    let isActive: Bool

    var body: some View {
        if isActive {
            HStack(spacing: 4) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10))
                Text("Plan Mode")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.tronAmber)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.tronAmber.opacity(0.15))
            .clipShape(Capsule())
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("Plan Mode Entered") {
    VStack(spacing: 16) {
        PlanModeEnteredView(
            skillName: "plan",
            blockedTools: ["Write", "Edit", "Bash"]
        )

        PlanModeExitedView(
            reason: "approved",
            planPath: "/Users/test/.tron/plans/2026-01-14-120000-implement-feature.md"
        )

        PlanModeExitedView(
            reason: "cancelled",
            planPath: nil
        )

        PlanModeExitedView(
            reason: "timeout",
            planPath: nil
        )

        PlanModePill(isActive: true)
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
