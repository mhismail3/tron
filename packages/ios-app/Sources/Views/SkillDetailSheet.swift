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
                // Background
                Color.tronBackground.ignoresSafeArea()

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
            .navigationTitle(skill.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.tronEmerald)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    skillInfoBadge
                }
            }
        }
        .task {
            await loadSkillContent()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.tronEmerald)
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
                    .foregroundStyle(.tronEmerald)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.tronEmerald.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding()
    }

    private func contentView(_ metadata: SkillMetadata) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header card
                headerCard(metadata)

                // Content
                contentCard(metadata)

                // Additional files (if any)
                if !metadata.additionalFiles.isEmpty {
                    additionalFilesCard(metadata)
                }
            }
            .padding()
        }
    }

    private func headerCard(_ metadata: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Description
            Text(metadata.description)
                .font(.system(size: 15))
                .foregroundStyle(.tronTextPrimary)
                .lineSpacing(4)

            Divider()
                .background(.tronBorder)

            // Metadata row
            HStack(spacing: 16) {
                // Source
                HStack(spacing: 6) {
                    Image(systemName: metadata.source == .project ? "folder.fill" : "globe")
                        .font(.system(size: 11))
                    Text(metadata.source == .project ? "Project" : "Global")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.tronEmerald)

                // Auto-inject indicator
                if metadata.autoInject {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                        Text("Auto-inject")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.tronAmber)
                }

                Spacer()

                // Tags
                if let tags = metadata.tags, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tronCyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.tronCyan.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        )
    }

    private func contentCard(_ metadata: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronEmerald)

                Text("SKILL.md")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tronTextPrimary)

                Spacer()

                // Copy button
                Button {
                    UIPasteboard.general.string = metadata.content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            Divider()
                .background(.tronBorder)

            // Markdown content
            Text(LocalizedStringKey(metadata.content))
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.tronTextPrimary)
                .lineSpacing(6)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        )
    }

    private func additionalFilesCard(_ metadata: SkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tronEmerald)

                Text("Additional Files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)

                Spacer()

                Text("\(metadata.additionalFiles.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }

            Divider()
                .background(.tronBorder)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(metadata.additionalFiles, id: \.self) { file in
                    HStack(spacing: 8) {
                        Image(systemName: fileIcon(for: file))
                            .font(.system(size: 12))
                            .foregroundStyle(.tronTextMuted)
                            .frame(width: 20)

                        Text(file)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 0.5)
        )
    }

    private var skillInfoBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: skill.autoInject ? "bolt.fill" : "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(skill.autoInject ? .tronAmber : .tronCyan)

            Text(skill.autoInject ? "Rule" : "Skill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(skill.autoInject ? .tronAmber : .tronCyan)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((skill.autoInject ? Color.tronAmber : Color.tronCyan).opacity(0.15))
        .clipShape(Capsule())
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
            description: "TypeScript coding standards and best practices for the project",
            source: .global,
            autoInject: false,
            tags: ["coding", "typescript"]
        ),
        skillStore: SkillStore()
    )
    .preferredColorScheme(.dark)
}
