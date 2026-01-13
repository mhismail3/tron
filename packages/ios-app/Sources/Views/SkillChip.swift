import SwiftUI

// MARK: - Skill Chip (iOS 26 Liquid Glass)

/// Compact glassy chip for displaying a skill reference
/// Used in InputBar (before sending) and MessageBubble (after sending)
@available(iOS 26.0, *)
struct SkillChip: View {
    let skill: Skill
    var showRemoveButton: Bool = false
    var onRemove: (() -> Void)?
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 5) {
                // Skill icon
                Image(systemName: skill.autoInject ? "bolt.fill" : "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skill.autoInject ? .tronAmber : .tronCyan)

                // Skill name
                Text("@\(skill.name)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                // Source indicator (subtle)
                if skill.source == .project {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tronEmerald.opacity(0.6))
                }

                // Remove button (only in input bar mode)
                if showRemoveButton {
                    Button {
                        onRemove?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(chipTintColor.opacity(0.4)),
                        in: .capsule
                    )
            }
            .overlay(
                Capsule()
                    .strokeBorder(chipBorderColor.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var chipTintColor: Color {
        skill.autoInject ? .tronAmber : .tronCyan
    }

    private var chipBorderColor: Color {
        skill.autoInject ? .tronAmber : .tronCyan
    }
}

// MARK: - Skill Chip Row (for InputBar)

/// Horizontal scrollable row of skill chips for display above input bar
@available(iOS 26.0, *)
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

/// Row of skill chips displayed in sent messages (no remove button)
/// Aligned to trailing edge for user messages
@available(iOS 26.0, *)
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

// MARK: - Fallback for older iOS

struct SkillChipFallback: View {
    let skill: Skill
    var showRemoveButton: Bool = false
    var onRemove: (() -> Void)?
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: skill.autoInject ? "bolt.fill" : "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(skill.autoInject ? .orange : .cyan)

                Text("@\(skill.name)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                if skill.source == .project {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.green.opacity(0.6))
                }

                if showRemoveButton {
                    Button {
                        onRemove?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
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
                    description: "TypeScript coding standards",
                    source: .global,
                    autoInject: false,
                    tags: ["coding"]
                )
            )

            SkillChip(
                skill: Skill(
                    name: "project-context",
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
                Skill(name: "api-design", description: "API design patterns", source: .global, autoInject: false, tags: nil),
                Skill(name: "testing", description: "Testing best practices", source: .project, autoInject: false, tags: nil),
                Skill(name: "rules", description: "Project rules", source: .global, autoInject: true, tags: nil)
            ],
            onRemove: { _ in },
            onTap: { _ in }
        )

        // Message chips (read-only)
        MessageSkillChips(
            skills: [
                Skill(name: "swift-style", description: "Swift coding style", source: .global, autoInject: false, tags: nil)
            ],
            onTap: { _ in }
        )
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
