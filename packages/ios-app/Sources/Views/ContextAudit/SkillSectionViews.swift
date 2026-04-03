import SwiftUI

// MARK: - Skill References Section (standalone container, frontmatter only, not removable)

@available(iOS 26.0, *)
struct SkillReferencesSection: View {
    let skills: [Skill]
    /// Server-reported token count for the skill index (from breakdown.skillIndex).
    /// When nil, falls back to a rough estimate.
    var serverTokens: Int?
    @State private var isExpanded = false

    /// Token count: use server-reported value when available, else estimate
    private var displayTokens: Int {
        if let server = serverTokens, server > 0 {
            return server
        }
        return skills.reduce(0) { total, skill in
            let descriptionTokens = skill.description.count / 4
            let metadataTokens = 20
            return total + descriptionTokens + metadataTokens
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronCyan)
                    .frame(width: 18)
                Text("Skill References")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronCyan)

                // Count badge
                Text("\(skills.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronCyan)

                Spacer()

                // Token count
                Text(TokenFormatter.format(displayTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content - list of skill references (frontmatter only, lazy for performance)
            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(skills) { skill in
                        SkillReferenceRow(skill: skill)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronCyan)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Project Skills Section (auto-loaded project skills, scoped to sub-packages)

@available(iOS 26.0, *)
struct ProjectSkillsSection: View {
    let skills: [Skill]
    var serverTokens: Int?
    @State private var isExpanded = false

    private var displayTokens: Int {
        if let server = serverTokens, server > 0 {
            return server
        }
        return skills.reduce(0) { total, skill in
            let descriptionTokens = skill.description.count / 4
            let metadataTokens = 20
            return total + descriptionTokens + metadataTokens
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                Text("Project Skills")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)

                Text("\(skills.count)")
                    .font(TronTypography.pillValue)
                    .countBadge(.tronEmerald)

                Spacer()

                Text(TokenFormatter.format(displayTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(skills) { skill in
                        ProjectSkillRow(skill: skill)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(.tronEmerald)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Project Skill Row (shows scope directory)

@available(iOS 26.0, *)
struct ProjectSkillRow: View {
    let skill: Skill

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronEmerald)

                Text("@\(skill.name)")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronEmerald)

                Spacer()

                if let scope = skill.scopeDir, !scope.isEmpty {
                    Text(scope)
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                    .foregroundStyle(.tronTextDisabled)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                ContextMarkdownContent(content: skill.description)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .sectionFill(.tronEmerald, cornerRadius: 6, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Skill Reference Row (lightweight, no delete option)

@available(iOS 26.0, *)
struct SkillReferenceRow: View {
    let skill: Skill

    @State private var isExpanded = false

    private var sourceIcon: String {
        skill.source == .project ? "folder.fill" : "globe"
    }

    private var sourceColor: Color {
        skill.source == .project ? .tronEmerald : .tronCyan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(sourceColor)

                Text("@\(skill.name)")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronCyan)

                Spacer()

                // Tags if any
                if let tags = skill.tags, !tags.isEmpty {
                    Text(tags.prefix(2).joined(separator: ", "))
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                    .foregroundStyle(.tronTextDisabled)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expanded description (just description, not full content)
            if isExpanded {
                ContextMarkdownContent(content: skill.description)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .sectionFill(sourceColor, cornerRadius: 6, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // No context menu - skill references are not removable
    }
}

// MARK: - Added Skill Row (shows full SKILL.md content, deletable)

@available(iOS 26.0, *)
struct AddedSkillRow: View {
    let skill: AddedSkillInfo
    var onDelete: (() -> Void)?
    var onFetchContent: ((String) async -> String?)?

    @State private var isExpanded = false
    @State private var fullContent: String?
    @State private var isLoadingContent = false

    private var sourceIcon: String {
        skill.source == .project ? "folder.fill" : "globe"
    }

    private var sourceColor: Color {
        skill.source == .project ? .tronEmerald : .tronCyan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: sourceIcon)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronCyan)

                Text("@\(skill.name)")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronCyan)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                    .foregroundStyle(.tronTextDisabled)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
                // Fetch content on first expand
                if isExpanded && fullContent == nil && !isLoadingContent {
                    Task {
                        await fetchContent()
                    }
                }
            }

            // Expanded full content (scrollable SKILL.md)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Full SKILL.md content
                    if isLoadingContent {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.tronCyan)
                            Text("Loading content...")
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                    } else if let content = fullContent {
                        ScrollView {
                            ContextMarkdownContent(content: content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 300)
                        .sectionFill(.tronCyan, cornerRadius: 6, subtle: true)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(.horizontal, 8)
                    } else {
                        Text("Content not available")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .padding(8)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .sectionFill(.tronCyan, cornerRadius: 6, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contextMenu {
            if onDelete != nil {
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Remove from Context", systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    private func fetchContent() async {
        isLoadingContent = true
        if let fetch = onFetchContent {
            fullContent = await fetch(skill.name)
        }
        isLoadingContent = false
    }
}
