import SwiftUI

// MARK: - Mention Style

/// Configuration that captures the visual differences between Skill (@) and Spell (%) popups.
struct MentionStyle: Sendable {
    let title: String
    let icon: String
    let tintColor: Color
    let prefix: String
    let rowIcon: @Sendable (Skill) -> (name: String, color: Color)
    let badges: @Sendable (Skill) -> [MentionBadge]

    static let skill = MentionStyle(
        title: "Skills",
        icon: "sparkles",
        tintColor: .tronCyan,
        prefix: "@",
        rowIcon: { skill in
            skill.autoInject
                ? (name: "bolt.fill", color: .tronAmber)
                : (name: "sparkles", color: .tronCyan)
        },
        badges: { skill in
            var badges: [MentionBadge] = []
            if skill.source == .project {
                badges.append(MentionBadge(text: "project", color: .tronEmerald))
            }
            if skill.autoInject {
                badges.append(MentionBadge(text: "rule", color: .tronAmber))
            }
            return badges
        }
    )

    static let spell = MentionStyle(
        title: "Spells",
        icon: "wand.and.stars",
        tintColor: .tronPink,
        prefix: "%",
        rowIcon: { _ in
            (name: "wand.and.stars", color: .tronPink)
        },
        badges: { skill in
            var badges: [MentionBadge] = []
            if skill.source == .project {
                badges.append(MentionBadge(text: "project", color: .tronEmerald))
            }
            badges.append(MentionBadge(text: "one-time", color: .tronPink))
            return badges
        }
    )
}

// MARK: - Mention Badge

struct MentionBadge {
    let text: String
    let color: Color
}

// MARK: - Mention Popup

@available(iOS 26.0, *)
struct MentionPopup: View {
    let skills: [Skill]
    let query: String
    let style: MentionStyle
    let onSelect: (Skill) -> Void
    let onDismiss: () -> Void

    private var filteredSkills: [Skill] {
        MentionDetector.filterSkills(skills, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with dismiss button
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: style.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .semibold))
                        .foregroundStyle(style.tintColor)

                    Text(style.title)
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(style.tintColor)

                    if !query.isEmpty {
                        Text("· \"\(query)\"")
                            .font(TronTypography.sans(size: TronTypography.sizeBody2))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.tertiary)

                    Text("No skills found")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSkills) { skill in
                            MentionRow(skill: skill, style: style) {
                                onSelect(skill)
                            }
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
                    .regular.tint(style.tintColor.opacity(0.15)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }
}

// MARK: - Mention Row

@available(iOS 26.0, *)
private struct MentionRow: View {
    let skill: Skill
    let style: MentionStyle
    let onTap: () -> Void

    var body: some View {
        let icon = style.rowIcon(skill)
        let badges = style.badges(skill)

        Button {
            onTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    Circle()
                        .fill(icon.color.opacity(0.15))
                        .frame(width: 32, height: 32)

                    Image(systemName: icon.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(icon.color)
                }

                // Skill info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("\(style.prefix)\(skill.name)")
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.primary)

                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            Text(badge.text)
                                .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                                .foregroundStyle(badge.color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(badge.color.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    Text(skill.description)
                        .font(TronTypography.sans(size: TronTypography.sizeBody2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Add indicator
                Image(systemName: "plus.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                    .foregroundStyle(style.tintColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
