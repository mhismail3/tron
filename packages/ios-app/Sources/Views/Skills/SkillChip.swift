import SwiftUI

// MARK: - Chip Mode

/// Mode for chip display: skill (cyan) or spell (pink)
enum ChipMode {
    case skill   // Cyan color, sparkles icon (persistent)
    case spell   // Pink color, wand.and.stars icon (ephemeral)
}

// MARK: - Skill Chip (iOS 26 Liquid Glass)

/// Compact glassy chip for displaying a skill or spell reference
/// Used in InputBar (before sending) and MessageBubble (after sending)
@available(iOS 26.0, *)
struct SkillChip: View {
    let skill: Skill
    var mode: ChipMode = .skill
    var showRemoveButton: Bool = false
    var onRemove: (() -> Void)?
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            // Chip icon based on mode
            Image(systemName: chipIcon)
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(chipIconColor)

            // Skill/spell name
            Text(skill.name)
                .font(TronTypography.filePath)
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)

            // Source indicator (subtle) - only for skills
            if mode == .skill && skill.source == .project {
                Image(systemName: "folder.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeXXS))
                    .foregroundStyle(.tronEmerald.opacity(0.6))
            }

            // Remove button (only in input bar mode)
            if showRemoveButton {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronTextSecondary)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(
            .regular.tint(chipTintColor.opacity(0.4)).interactive(),
            in: .capsule
        )
        .contentShape(Capsule())
        .onTapGesture {
            onTap?()
        }
    }

    private var chipIcon: String {
        switch mode {
        case .skill:
            return skill.autoInject ? "bolt.fill" : "sparkles"
        case .spell:
            return "wand.and.stars"
        }
    }

    private var chipIconColor: Color {
        switch mode {
        case .skill:
            return skill.autoInject ? .tronAmber : .tronCyan
        case .spell:
            return .tronPink
        }
    }

    private var chipTintColor: Color {
        switch mode {
        case .skill:
            return skill.autoInject ? .tronAmber : .tronCyan
        case .spell:
            return .tronPink
        }
    }

    private var chipBorderColor: Color {
        chipTintColor
    }
}

// MARK: - Skill Chip Row (for InputBar)

/// Horizontal scrollable row of skill chips for display above input bar
@available(iOS 26.0, *)
struct SkillChipRow: View {
    let skills: [Skill]
    var mode: ChipMode = .skill
    let onRemove: (Skill) -> Void
    let onTap: (Skill) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(skills) { skill in
                    SkillChip(
                        skill: skill,
                        mode: mode,
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

// MARK: - Spell Chip Row (for InputBar - ephemeral spells)

/// Horizontal scrollable row of spell chips for display above input bar
@available(iOS 26.0, *)
struct SpellChipRow: View {
    let spells: [Skill]
    let onRemove: (Skill) -> Void
    let onTap: (Skill) -> Void

    var body: some View {
        SkillChipRow(
            skills: spells,
            mode: .spell,
            onRemove: onRemove,
            onTap: onTap
        )
    }
}

// MARK: - Message Skill Chips (for MessageBubble - read-only)

/// Row of skill chips displayed in sent messages (no remove button)
/// Aligned to trailing edge for user messages
@available(iOS 26.0, *)
struct MessageSkillChips: View {
    let skills: [Skill]
    var mode: ChipMode = .skill
    let onTap: (Skill) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(skills) { skill in
                SkillChip(
                    skill: skill,
                    mode: mode,
                    showRemoveButton: false,
                    onTap: { onTap(skill) }
                )
            }
        }
    }
}

// MARK: - Message Spell Chips (for MessageBubble - read-only)

/// Row of spell chips displayed in sent messages (no remove button)
@available(iOS 26.0, *)
struct MessageSpellChips: View {
    let spells: [Skill]
    let onTap: (Skill) -> Void

    var body: some View {
        MessageSkillChips(
            skills: spells,
            mode: .spell,
            onTap: onTap
        )
    }
}

// MARK: - Fallback for older iOS

struct SkillChipFallback: View {
    let skill: Skill
    var mode: ChipMode = .skill
    var showRemoveButton: Bool = false
    var onRemove: (() -> Void)?
    var onTap: (() -> Void)?

    private var iconName: String {
        switch mode {
        case .skill:
            return skill.autoInject ? "bolt.fill" : "sparkles"
        case .spell:
            return "wand.and.stars"
        }
    }

    private var iconColor: Color {
        switch mode {
        case .skill:
            return skill.autoInject ? .orange : .cyan
        case .spell:
            return .tronPink
        }
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(iconColor)

                Text(skill.name)
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                if skill.source == .project {
                    Image(systemName: "folder.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeXXS))
                        .foregroundStyle(.green.opacity(0.6))
                }

                if showRemoveButton {
                    Button {
                        onRemove?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.tronOverlay(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    VStack(spacing: 20) {
        // Single skill chips
        HStack {
            SkillChip(
                skill: Skill(
                    name: "typescript-rules",
                    displayName: "TypeScript Rules",
                    description: "TypeScript coding standards",
                    source: .global,
                    autoInject: false,
                    tags: ["coding"]
                )
            )

            SkillChip(
                skill: Skill(
                    name: "project-context",
                    displayName: "Project Context",
                    description: "Project-specific context",
                    source: .project,
                    autoInject: true,
                    tags: ["context"]
                )
            )
        }

        // Row with remove buttons (InputBar style)
        SkillChipRow(
            skills: [
                Skill(name: "api-design", displayName: "API Design", description: "API design patterns", source: .global, autoInject: false, tags: nil),
                Skill(name: "testing", displayName: "Testing", description: "Testing best practices", source: .project, autoInject: false, tags: nil),
                Skill(name: "rules", displayName: "Rules", description: "Project rules", source: .global, autoInject: true, tags: nil)
            ],
            onRemove: { _ in },
            onTap: { _ in }
        )

        // Message chips (read-only)
        MessageSkillChips(
            skills: [
                Skill(name: "swift-style", displayName: "Swift Style", description: "Swift coding style", source: .global, autoInject: false, tags: nil)
            ],
            onTap: { _ in }
        )
    }
    .padding()
    .background(Color.tronBackground)
}
