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
                .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                .foregroundStyle(.tronAmber)

            VStack(alignment: .leading, spacing: 2) {
                Text("Plan Mode Active")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.tronAmber)

                Text("Read-only until plan is approved")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
            }

            Spacer()

            // Skill name badge
            Text(skillName)
                .font(TronTypography.filePath)
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
                .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                .foregroundStyle(reasonColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(reasonText)
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(reasonColor)

                if reason == "approved", let path = planPath {
                    // Show truncated plan path
                    Text(truncatePath(path))
                        .font(TronTypography.codeCaption)
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
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                Text("Plan Mode")
                    .font(TronTypography.pillValue)
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
