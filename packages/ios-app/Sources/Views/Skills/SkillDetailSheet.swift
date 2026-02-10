import SwiftUI

// MARK: - Skill Detail Sheet (iOS 26 Liquid Glass)

/// Full-screen sheet for reading skill content when a skill chip is tapped
/// Displays the SKILL.md content in a beautiful, readable format
/// Supports both skill (cyan) and spell (pink) modes
@available(iOS 26.0, *)
struct SkillDetailSheet: View {
    let skill: Skill
    let skillStore: SkillStore
    var mode: ChipMode = .skill
    @Environment(\.dismiss) private var dismiss

    @State private var skillMetadata: SkillMetadata?
    @State private var isLoading = true
    @State private var error: String?

    /// Accent color based on mode: cyan for skills, pink for spells
    private var accentColor: Color {
        switch mode {
        case .skill: return .tronCyan
        case .spell: return .tronPink
        }
    }

    /// Icon for the mode: sparkles for skills, wand for spells
    private var modeIcon: String {
        switch mode {
        case .skill: return "sparkles"
        case .spell: return "wand.and.stars"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    loadingView
                } else if let error = error {
                    errorView(error)
                } else if let metadata = skillMetadata {
                    contentView(metadata)
                } else {
                    errorView("Skill not found")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(skill.displayName)
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(accentColor)
        .task {
            await loadSkillContent()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(accentColor)
                .scaleEffect(1.2)

            Text("Loading skill content...")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextMuted)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.sans(size: 40))
                .foregroundStyle(.tronError)

            Text("Failed to load skill")
                .font(TronTypography.button)
                .foregroundStyle(.tronTextPrimary)

            Text(message)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)

            Button {
                Task { await loadSkillContent() }
            } label: {
                Text("Try Again")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding()
    }

    private func contentView(_ metadata: SkillMetadata) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                // Description section
                descriptionSection(metadata)
                    .padding(.horizontal)

                // Content section
                contentSection(metadata)
                    .padding(.horizontal)

                // Additional files section (always shown)
                additionalFilesSection(metadata)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    // MARK: - Sections (matching Context Manager style)

    private func descriptionSection(_ metadata: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header (outside the card, like Context Manager)
            Text("Description")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            // Card content
            VStack(spacing: 12) {
                // Description text
                Text(metadata.description)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Metadata row
                HStack(spacing: 8) {
                    // Source badge (emerald for project scope visibility)
                    HStack(spacing: 4) {
                        Image(systemName: metadata.source == .project ? "folder.fill" : "globe")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text(metadata.source == .project ? "Project" : "Global")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    }
                    .foregroundStyle(.tronEmerald)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.25)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    Spacer()

                    // Tags (purple for visual distinction)
                    if let tags = metadata.tags, !tags.isEmpty {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronPurple.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.clear)
                                        .glassEffect(.regular.tint(Color.tronPurple.opacity(0.2)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                        }
                    }
                }

                // Ephemeral spell caption (only for spells)
                if mode == .spell {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text("Spells are ephemeral one-time skills that apply only to a single prompt.")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    }
                    .foregroundStyle(accentColor.opacity(0.8))
                    .padding(.top, 4)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func contentSection(_ metadata: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text("SKILL.md")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                // Copy button
                Button {
                    UIPasteboard.general.string = metadata.content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(accentColor.opacity(0.6))
                }
            }

            // Card content
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(accentColor)

                    Text("Content")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(accentColor)

                    Spacer()
                }

                // Markdown content
                Text(TextContentView.markdownAttributedString(from: metadata.content))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func additionalFilesSection(_ metadata: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Other Files")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            if metadata.additionalFiles.isEmpty {
                // Empty state
                Text("No other files")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextDisabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Card content with files
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(metadata.additionalFiles, id: \.self) { file in
                        HStack(spacing: 8) {
                            Image(systemName: fileIcon(for: file))
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                                .foregroundStyle(accentColor.opacity(0.8))

                            Text(file)
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                                .foregroundStyle(.tronTextSecondary)

                            Spacer()
                        }
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.clear)
                                .glassEffect(.regular.tint(accentColor.opacity(0.15)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    // MARK: - Helpers

    private func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            return "doc.text"
        case "json":
            return "curlybraces"
        case "py":
            return "chevron.left.forwardslash.chevron.right"
        case "ts", "js":
            return "chevron.left.forwardslash.chevron.right"
        case "swift":
            return "swift"
        case "sh", "bash":
            return "terminal"
        case "yml", "yaml":
            return "list.bullet"
        default:
            return "doc"
        }
    }

    private func loadSkillContent() async {
        isLoading = true
        error = nil

        if let metadata = await skillStore.getSkill(name: skill.name) {
            skillMetadata = metadata
        } else {
            error = "Could not load skill content"
        }

        isLoading = false
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview {
    SkillDetailSheet(
        skill: Skill(
            name: "typescript-rules",
            displayName: "TypeScript Rules",
            description: "TypeScript coding standards and best practices for the project",
            source: .global,
            tags: ["coding", "typescript"]
        ),
        skillStore: SkillStore()
    )
}
