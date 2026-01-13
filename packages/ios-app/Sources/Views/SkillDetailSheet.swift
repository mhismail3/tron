import SwiftUI

// MARK: - Skill Detail Sheet (iOS 26 Liquid Glass)

/// Full-screen sheet for reading skill content when a skill chip is tapped
/// Displays the SKILL.md content in a beautiful, readable format
@available(iOS 26.0, *)
struct SkillDetailSheet: View {
    let skill: Skill
    let skillStore: SkillStore
    @Environment(\.dismiss) private var dismiss

    @State private var skillMetadata: SkillMetadata?
    @State private var isLoading = true
    @State private var error: String?

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
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronCyan)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronCyan)
        .preferredColorScheme(.dark)
        .task {
            await loadSkillContent()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.tronCyan)
                .scaleEffect(1.2)

            Text("Loading skill content...")
                .font(.system(size: 14))
                .foregroundStyle(.tronTextMuted)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tronError)

            Text("Failed to load skill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)

            Button {
                Task { await loadSkillContent() }
            } label: {
                Text("Try Again")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tronCyan)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.tronCyan.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding()
    }

    private func contentView(_ metadata: SkillMetadata) -> some View {
        ScrollView {
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
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            // Card content
            VStack(spacing: 12) {
                // Description text
                Text(metadata.description)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronCyan)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Metadata row
                HStack(spacing: 8) {
                    // Source badge (emerald for project scope visibility)
                    HStack(spacing: 4) {
                        Image(systemName: metadata.source == .project ? "folder.fill" : "globe")
                            .font(.system(size: 10))
                        Text(metadata.source == .project ? "Project" : "Global")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(.tronEmerald)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.25)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Auto-inject badge
                    if metadata.autoInject {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                            Text("Auto-inject")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.tronAmber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.clear)
                                .glassEffect(.regular.tint(Color.tronAmber.opacity(0.25)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }

                    Spacer()

                    // Tags (purple for visual distinction)
                    if let tags = metadata.tags, !tags.isEmpty {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
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
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronCyan.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func contentSection(_ metadata: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text("SKILL.md")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // Copy button
                Button {
                    UIPasteboard.general.string = metadata.content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.tronCyan.opacity(0.6))
                }
            }

            // Card content
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronCyan)

                    Text("Content")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronCyan)

                    Spacer()
                }

                // Markdown content
                Text(LocalizedStringKey(metadata.content))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronCyan.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func additionalFilesSection(_ metadata: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Other Files")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            if metadata.additionalFiles.isEmpty {
                // Empty state
                Text("No other files")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Card content with files
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(metadata.additionalFiles, id: \.self) { file in
                        HStack(spacing: 8) {
                            Image(systemName: fileIcon(for: file))
                                .font(.system(size: 12))
                                .foregroundStyle(.tronCyan.opacity(0.8))

                            Text(file)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))

                            Spacer()
                        }
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.clear)
                                .glassEffect(.regular.tint(Color.tronCyan.opacity(0.15)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(Color.tronCyan.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            autoInject: false,
            tags: ["coding", "typescript"]
        ),
        skillStore: SkillStore()
    )
    .preferredColorScheme(.dark)
}
