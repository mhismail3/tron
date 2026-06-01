import SwiftUI

// MARK: - Skill Chip

/// Compact chip for displaying a skill reference.
/// Used in InputBar (before sending) and MessageBubble (after sending).
struct SkillChip: View {
    let skill: Skill
    var showRemoveButton: Bool = false
    var onRemove: (() -> Void)?
    var onTap: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors { .skill(colorScheme) }

    var body: some View {
        if showRemoveButton {
            removableChip
        } else {
            readOnlyChip
        }
    }

    private var readOnlyChip: some View {
        skillLabel
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .chipStyleMaterial(tint.accent, tintOpacity: 0.4)
            .contentShape(Capsule())
            .onTapGesture {
                onTap?()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SkillChipAccessibility.skillLabel(skill.name))
            .accessibilityAddTraits(.isButton)
    }

    private var removableChip: some View {
        HStack(spacing: 5) {
            Button {
                onTap?()
            } label: {
                skillLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SkillChipAccessibility.skillLabel(skill.name))

            Button {
                onRemove?()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.dismiss)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .accessibilityLabel(SkillChipAccessibility.removeLabel(skill.name))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .chipStyleMaterial(tint.accent, tintOpacity: 0.4)
    }

    private var skillLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(tint.accent)

            SkillBadges(skill: skill, style: .icon)

            Text(skill.name)
                .font(TronTypography.filePath)
                .foregroundStyle(tint.name)
                .lineLimit(1)
        }
    }
}

enum SkillChipAccessibility {
    static func skillLabel(_ name: String) -> String {
        "Skill, \(name)"
    }

    static func removeLabel(_ name: String) -> String {
        "Remove skill, \(name)"
    }
}

// MARK: - Message Skill Chips (for MessageBubble - read-only)

/// Row of skill chips displayed in sent messages (no remove button).
/// Aligned to trailing edge for user messages.
struct MessageSkillChips: View {
    let skills: [Skill]
    let onTap: (Skill) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(skills) { skill in
                SkillChip(
                    skill: skill,
                    showRemoveButton: false,
                    onTap: { onTap(skill) }
                )
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        HStack {
            SkillChip(
                skill: Skill(
                    name: "typescript-rules",
                    displayName: "TypeScript Rules",
                    description: "TypeScript coding standards",
                    source: .global,
                    tags: ["coding"]
                )
            )

            SkillChip(
                skill: Skill(
                    name: "project-context",
                    displayName: "Project Context",
                    description: "Project-specific context",
                    source: .project,
                    tags: ["context"]
                )
            )
        }

        MessageSkillChips(
            skills: [
                Skill(name: "swift-style", displayName: "Swift Style", description: "Swift coding style", source: .global, tags: nil)
            ],
            onTap: { _ in }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
#endif
