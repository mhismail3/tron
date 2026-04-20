import SwiftUI

// MARK: - Skill Badges

/// Provenance badges for a skill: `project` vs `global` plus which service folder
/// produced it (`tron`, `claude`, …). Orthogonal axes — both can render at once
/// for a claude-project skill.
///
/// Two rendering styles:
/// - `.capsule` — text pill, used in picker rows + context-sheet lists.
/// - `.icon` — SF Symbol only, used in compact chips.
struct SkillBadges: View {
    let skill: Skill
    let style: Style

    enum Style {
        case capsule
        case icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if skill.source == .project {
                switch style {
                case .capsule:
                    ProjectCapsule()
                case .icon:
                    ProjectIcon()
                }
            }
            if skill.serviceTag == .claude {
                switch style {
                case .capsule:
                    ClaudeCapsule()
                case .icon:
                    ClaudeIcon()
                }
            }
        }
    }
}

// MARK: - Project badges

private struct ProjectCapsule: View {
    var body: some View {
        Text("project")
            .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            .foregroundStyle(.tronEmerald)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.tronEmerald.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityLabel("Project skill")
    }
}

private struct ProjectIcon: View {
    var body: some View {
        Image(systemName: "folder.fill")
            .font(TronTypography.sans(size: TronTypography.sizeXXS))
            .foregroundStyle(.tronEmerald.opacity(0.6))
            .accessibilityLabel("Project skill")
    }
}

// MARK: - Claude badges

private struct ClaudeCapsule: View {
    var body: some View {
        Text("claude")
            .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            .foregroundStyle(.tronCoral)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.tronCoral.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityLabel("From Claude skills directory")
    }
}

private struct ClaudeIcon: View {
    var body: some View {
        Image(systemName: "c.circle.fill")
            .font(TronTypography.sans(size: TronTypography.sizeXXS))
            .foregroundStyle(.tronCoral.opacity(0.7))
            .accessibilityLabel("From Claude skills directory")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Badges") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Capsule style").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 12) {
            SkillBadges(
                skill: Skill(name: "a", displayName: "a", description: "", source: .global, tags: nil, service: "tron"),
                style: .capsule
            )
            SkillBadges(
                skill: Skill(name: "b", displayName: "b", description: "", source: .global, tags: nil, service: "claude"),
                style: .capsule
            )
            SkillBadges(
                skill: Skill(name: "c", displayName: "c", description: "", source: .project, tags: nil, service: "tron"),
                style: .capsule
            )
            SkillBadges(
                skill: Skill(name: "d", displayName: "d", description: "", source: .project, tags: nil, service: "claude"),
                style: .capsule
            )
        }

        Text("Icon style").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 12) {
            SkillBadges(
                skill: Skill(name: "a", displayName: "a", description: "", source: .global, tags: nil, service: "tron"),
                style: .icon
            )
            SkillBadges(
                skill: Skill(name: "b", displayName: "b", description: "", source: .global, tags: nil, service: "claude"),
                style: .icon
            )
            SkillBadges(
                skill: Skill(name: "c", displayName: "c", description: "", source: .project, tags: nil, service: "tron"),
                style: .icon
            )
            SkillBadges(
                skill: Skill(name: "d", displayName: "d", description: "", source: .project, tags: nil, service: "claude"),
                style: .icon
            )
        }
    }
    .padding()
}
#endif
