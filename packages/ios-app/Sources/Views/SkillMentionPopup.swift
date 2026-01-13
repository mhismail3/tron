import SwiftUI

// MARK: - Skill Mention Popup (iOS 26 Liquid Glass)

/// Non-blocking popup that appears above the input bar when typing @
/// Shows a filtered list of skills based on the query text after @
@available(iOS 26.0, *)
struct SkillMentionPopup: View {
    let skills: [Skill]
    let query: String
    let onSelect: (Skill) -> Void
    let onDismiss: () -> Void

    /// Fuzzy filter skills based on query
    private var filteredSkills: [Skill] {
        guard !query.isEmpty else { return skills }

        let lowercasedQuery = query.lowercased()
        return skills.filter { skill in
            // Match name (primary)
            if skill.name.lowercased().contains(lowercasedQuery) {
                return true
            }
            // Match description (secondary)
            if skill.description.lowercased().contains(lowercasedQuery) {
                return true
            }
            // Match tags
            if let tags = skill.tags {
                return tags.contains { $0.lowercased().contains(lowercasedQuery) }
            }
            return false
        }.sorted { lhs, rhs in
            // Prioritize exact prefix matches
            let lhsPrefix = lhs.name.lowercased().hasPrefix(lowercasedQuery)
            let rhsPrefix = rhs.name.lowercased().hasPrefix(lowercasedQuery)
            if lhsPrefix != rhsPrefix { return lhsPrefix }

            // Then by name length (shorter = more specific)
            return lhs.name.count < rhs.name.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with dismiss button
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tronCyan)

                    Text("Skills")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    if !query.isEmpty {
                        Text("· \"\(query)\"")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Dismiss button
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
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
                // Empty state - compact
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)

                    Text("No skills found")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                // Size to content, max 4 items visible before scrolling
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSkills) { skill in
                            SkillMentionRow(skill: skill) {
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
                    .regular.tint(Color.tronEmerald.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }
}

// MARK: - Skill Mention Row

@available(iOS 26.0, *)
private struct SkillMentionRow: View {
    let skill: Skill
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 10) {
                // Skill icon
                ZStack {
                    Circle()
                        .fill(skill.autoInject ? Color.tronAmber.opacity(0.15) : Color.tronCyan.opacity(0.15))
                        .frame(width: 32, height: 32)

                    Image(systemName: skill.autoInject ? "bolt.fill" : "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(skill.autoInject ? .tronAmber : .tronCyan)
                }

                // Skill info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("@\(skill.name)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)

                        // Source badge
                        if skill.source == .project {
                            Text("project")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tronEmerald)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.tronEmerald.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        // Auto-inject badge
                        if skill.autoInject {
                            Text("rule")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tronAmber)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.tronAmber.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    Text(skill.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Add indicator
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tronCyan)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skill Mention Detection Helper

/// Detects @mentions in text and extracts the current query
struct SkillMentionDetector {
    /// Check if the cursor is currently in a mention context
    /// Returns the query string after @ if in mention mode, nil otherwise
    static func detectMention(in text: String) -> String? {
        // Find the last @ that isn't escaped or in code
        guard let atIndex = text.lastIndex(of: "@") else { return nil }

        // Check if @ is at the start or preceded by whitespace/newline
        if atIndex != text.startIndex {
            let prevIndex = text.index(before: atIndex)
            let prevChar = text[prevIndex]
            // @ must be preceded by whitespace, newline, or be at start
            guard prevChar.isWhitespace || prevChar.isNewline else {
                return nil
            }
        }

        // Check if @ is inside backticks (code)
        let beforeAt = text[..<atIndex]
        let backtickCount = beforeAt.filter { $0 == "`" }.count
        if backtickCount % 2 != 0 {
            return nil // Inside code block
        }

        // Extract the query after @
        let afterAt = text[text.index(after: atIndex)...]

        // If there's a space after the query, mention is complete
        if afterAt.contains(" ") || afterAt.contains("\n") {
            return nil
        }

        return String(afterAt)
    }

    /// Check if text contains any @ that could start a mention
    static func couldBeMention(_ text: String) -> Bool {
        detectMention(in: text) != nil
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack {
            Spacer()

            SkillMentionPopup(
                skills: [
                    Skill(name: "typescript-rules", description: "TypeScript coding standards and best practices", source: .global, autoInject: false, tags: ["coding", "typescript"]),
                    Skill(name: "api-design", description: "RESTful API design patterns", source: .global, autoInject: false, tags: ["api"]),
                    Skill(name: "project-context", description: "Project-specific context and rules", source: .project, autoInject: true, tags: ["context"]),
                    Skill(name: "testing", description: "Testing best practices", source: .project, autoInject: false, tags: ["testing"])
                ],
                query: "type",
                onSelect: { _ in },
                onDismiss: {}
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
    }
    .preferredColorScheme(.dark)
}
