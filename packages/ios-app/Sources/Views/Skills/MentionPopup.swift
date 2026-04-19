import SwiftUI

// MARK: - Mention Popup

@available(iOS 26.0, *)
struct MentionPopup: View {
    let skills: [Skill]
    let query: String
    let skillStore: SkillStore?
    let onSelect: (Skill) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var detailSkill: Skill?

    private var tint: TintedColors { .skill(colorScheme) }

    private var filteredSkills: [Skill] {
        SkillMentions.filterSkills(skills, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with dismiss button
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .semibold))
                        .foregroundStyle(Color.tronCyan)

                    Text("Skills")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(Color.tronCyan)

                    if !query.isEmpty {
                        Text("· \"\(query)\"")
                            .font(TronTypography.sans(size: TronTypography.sizeBody2))
                            .foregroundStyle(tint.secondary)
                    }
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(tint.dismiss)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .padding(.top, 6)

            // Skills list
            if filteredSkills.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle))
                        .foregroundStyle(tint.subtle)

                    Text("No skills found")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(tint.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSkills) { skill in
                            MentionRow(skill: skill, tint: tint, onTap: {
                                onSelect(skill)
                            }, onInfo: {
                                detailSkill = skill
                            })
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(filteredSkills.count, 5)) * 48)
            }
        }
        .padding(.bottom, 6)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(Color.tronCyan.opacity(0.15)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
        .sheet(item: $detailSkill) { skill in
            if let store = skillStore {
                SkillDetailSheet(skill: skill, skillStore: store)
            }
        }
    }
}

// MARK: - Mention Row

@available(iOS 26.0, *)
private struct MentionRow: View {
    let skill: Skill
    let tint: TintedColors
    let onTap: () -> Void
    let onInfo: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    Circle()
                        .fill(Color.tronCyan.opacity(0.15))
                        .frame(width: 32, height: 32)

                    Image(systemName: "sparkles")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronCyan)
                }

                // Skill info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("@\(skill.name)")
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(tint.name)

                        if skill.source == .project {
                            Text("project")
                                .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                                .foregroundStyle(.tronEmerald)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.tronEmerald.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    Text(skill.description)
                        .font(TronTypography.sans(size: TronTypography.sizeBody2))
                        .foregroundStyle(tint.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Info button
                Button {
                    onInfo()
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                        .foregroundStyle(Color.tronCyan)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
