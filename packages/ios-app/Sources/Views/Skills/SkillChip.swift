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

    private var tint: TintedColors {
        TintedColors(accent: .tronCyan, colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(tint.accent)

            Text(skill.name)
                .font(TronTypography.filePath)
                .foregroundStyle(tint.name)
                .lineLimit(1)

            if skill.source == .project {
                Image(systemName: "folder.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeXXS))
                    .foregroundStyle(.tronEmerald.opacity(0.6))
            }

            if showRemoveButton {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(tint.dismiss)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .chipStyleMaterial(tint.accent, tintOpacity: 0.4)
        .contentShape(Capsule())
        .onTapGesture {
            onTap?()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skill, \(skill.name)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Skill Chip Row (for InputBar)

/// Horizontal scrollable row of skill chips for display above input bar.
struct SkillChipRow: View {
    let skills: [Skill]
    let onRemove: (Skill) -> Void
    let onTap: (Skill) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(skills) { skill in
                    SkillChip(
                        skill: skill,
                        showRemoveButton: true,
                        onRemove: { onRemove(skill) },
                        onTap: { onTap(skill) }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 32)
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

        SkillChipRow(
            skills: [
                Skill(name: "api-design", displayName: "API Design", description: "API design patterns", source: .global, tags: nil),
                Skill(name: "testing", displayName: "Testing", description: "Testing best practices", source: .project, tags: nil),
                Skill(name: "rules", displayName: "Rules", description: "Project rules", source: .global, tags: nil)
            ],
            onRemove: { _ in },
            onTap: { _ in }
        )

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
