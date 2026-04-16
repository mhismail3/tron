import SwiftUI

// MARK: - Context Detail View (pushed from Agent Control sheet)

@available(iOS 26.0, *)
struct ContextDetailView: View {
    let rpcClient: RPCClient
    let sessionId: String
    let snapshot: DetailedContextSnapshotResult
    var skillStore: SkillStore?
    var readOnly: Bool = false

    /// Skills being optimistically deleted
    var pendingSkillDeletions: Set<String>
    var onRemoveSkill: ((String) -> Void)?
    var onFetchSkillContent: ((String) async -> String?)?

    @Environment(\.dismiss) private var dismiss
    @State private var isClearing = false
    @State private var isCompacting = false
    @State private var showClearPopover = false
    @State private var showCompactPopover = false
    @State private var errorMessage: String?

    private var hasMessages: Bool {
        !snapshot.messages.isEmpty
    }

    /// Global rules (from ~/.tron/)
    private var globalRules: LoadedRules? {
        guard let rules = snapshot.rules else { return nil }
        let globalFiles = rules.files.filter { $0.level == .global }
        guard !globalFiles.isEmpty else { return nil }
        let share = rules.files.isEmpty ? 0 : rules.tokens * globalFiles.count / rules.files.count
        return LoadedRules(
            files: globalFiles,
            totalFiles: globalFiles.count,
            tokens: share
        )
    }

    /// Project rules (project + directory scoped)
    private var projectRules: LoadedRules? {
        guard let rules = snapshot.rules else { return nil }
        let projectFiles = rules.files.filter { $0.level == .project || $0.level == .directory }
        guard !projectFiles.isEmpty else { return nil }
        let share = rules.files.isEmpty ? 0 : rules.tokens * projectFiles.count / rules.files.count
        return LoadedRules(
            files: projectFiles,
            totalFiles: projectFiles.count,
            tokens: share
        )
    }

    /// Added skills filtered by pending deletions
    private var displayedAddedSkills: [AddedSkillInfo] {
        snapshot.addedSkills.filter { !pendingSkillDeletions.contains($0.name) }
    }

    var body: some View {
        NavigationStack {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 8) {
                // System Instructions
                sectionHeader("System Instructions", icon: "doc.text")

                VStack(spacing: 10) {
                    // Environment info
                    if let env = snapshot.environment {
                        VStack(spacing: 6) {
                            if let wd = env.workingDirectory {
                                let displayPath = wd.abbreviatingHomeDirectory
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                                        .foregroundStyle(.tronSlate)
                                        .frame(width: 18)
                                    Text("Working Directory")
                                        .font(TronTypography.codeCaption)
                                        .foregroundStyle(.tronTextMuted)
                                    Spacer()
                                    Text(displayPath)
                                        .font(TronTypography.codeCaption)
                                        .foregroundStyle(.tronTextSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, compact: false)
                            }
                            if let origin = env.serverOrigin {
                                HStack(spacing: 8) {
                                    Image(systemName: "network")
                                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                                        .foregroundStyle(.tronSlate)
                                        .frame(width: 18)
                                    Text("Server Origin")
                                        .font(TronTypography.codeCaption)
                                        .foregroundStyle(.tronTextMuted)
                                    Spacer()
                                    Text(origin)
                                        .font(TronTypography.codeCaption)
                                        .foregroundStyle(.tronTextSecondary)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, compact: false)
                            }
                        }
                    }

                    SystemPromptSection(
                        tokens: snapshot.breakdown.systemPrompt,
                        content: snapshot.systemPromptContent
                    )

                    ToolsSection(
                        toolsContent: snapshot.toolsContent,
                        tokens: snapshot.breakdown.tools
                    )
                }
                .padding(.horizontal)

                // Global Context
                if hasGlobalContent {
                    sectionHeader("Global Context", icon: "globe")
                        .padding(.top, 12)

                    VStack(spacing: 10) {
                        if let globalRules {
                            RulesSection(
                                rules: globalRules,
                                onFetchContent: { path in
                                    try await rpcClient.filesystem.readFile(path: path)
                                }
                            )
                        }

                        if let globalSkills = skillStore?.globalSkills, !globalSkills.isEmpty {
                            SkillReferencesSection(
                                skills: globalSkills,
                                tokens: snapshot.breakdown.skillIndex
                            )
                        }
                    }
                    .padding(.horizontal)
                }

                // Project Context
                if hasProjectContent {
                    sectionHeader("Project Context", icon: "folder.fill")
                        .padding(.top, 12)

                    VStack(spacing: 10) {
                        if let projectRules {
                            RulesSection(
                                rules: projectRules,
                                onFetchContent: { path in
                                    try await rpcClient.filesystem.readFile(path: path)
                                }
                            )
                        }

                        if let projectSkills = skillStore?.projectSkills, !projectSkills.isEmpty {
                            ProjectSkillsSection(
                                skills: projectSkills,
                                tokens: snapshot.breakdown.skillIndex
                            )
                        }
                    }
                    .padding(.horizontal)
                }

                // Session Context
                if hasSessionContent {
                    sectionHeader("Session Context", icon: "clock")
                        .padding(.top, 12)

                    VStack(spacing: 10) {
                        if !displayedAddedSkills.isEmpty {
                            AddedSkillsContainer(
                                skills: displayedAddedSkills,
                                tokens: snapshot.breakdown.skillContext,
                                onDelete: readOnly ? nil : { skillName in
                                    onRemoveSkill?(skillName)
                                },
                                onFetchContent: onFetchSkillContent
                            )
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                clearButton
            }
            ToolbarItem(placement: .principal) {
                SheetTitle(title: "Context", color: .tronCyan)
            }
            ToolbarItem(placement: .topBarTrailing) {
                compactButton
            }
        }
        .tronErrorAlert(message: $errorMessage)
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronCyan)
    }

    // MARK: - Section Headers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronCyan)
            Text(title)
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronCyan)
            Spacer()
        }
        .padding(.horizontal)
    }

    // MARK: - Content Checks

    /// Whether the session uses a local (Ollama) model.
    /// Local models don't use the skill index (catalog), but support manually activated skills.
    private var isLocalModel: Bool {
        snapshot.isLocalModel == true
    }

    private var hasGlobalContent: Bool {
        globalRules != nil || (!isLocalModel && !(skillStore?.globalSkills ?? []).isEmpty)
    }

    private var hasProjectContent: Bool {
        projectRules != nil || (!isLocalModel && !(skillStore?.projectSkills ?? []).isEmpty)
    }

    private var hasSessionContent: Bool {
        !displayedAddedSkills.isEmpty
    }

    // MARK: - Toolbar Buttons

    private var clearButton: some View {
        LoadingToolbarButton(
            label: "Clear",
            icon: "trash",
            color: .tronError,
            isLoading: isClearing,
            isEnabled: hasMessages && !readOnly
        ) {
            showClearPopover = true
        }
        .popover(isPresented: $showClearPopover, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Clear Context",
                        icon: "trash",
                        color: .tronError,
                        role: .destructive
                    ) {
                        showClearPopover = false
                        Task { await clearContext() }
                    },
                    GlassAction(
                        title: "Cancel",
                        icon: nil,
                        color: .tronTextMuted,
                        role: .cancel
                    ) {
                        showClearPopover = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var compactButton: some View {
        LoadingToolbarButton(
            label: "Compact",
            icon: "arrow.down.right.and.arrow.up.left",
            color: .tronSlate,
            isLoading: isCompacting,
            isEnabled: hasMessages && !readOnly
        ) {
            showCompactPopover = true
        }
        .popover(isPresented: $showCompactPopover, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Compact Context",
                        icon: "arrow.down.right.and.arrow.up.left",
                        color: .tronSlate,
                        role: .default
                    ) {
                        showCompactPopover = false
                        Task { await compactContext() }
                    },
                    GlassAction(
                        title: "Cancel",
                        icon: nil,
                        color: .tronTextMuted,
                        role: .cancel
                    ) {
                        showCompactPopover = false
                    }
                ]
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Actions

    private func clearContext() async {
        isClearing = true
        do {
            _ = try await rpcClient.context.clear(sessionId: sessionId)
        } catch {
            errorMessage = "Failed to clear context: \(error.localizedDescription)"
        }
        isClearing = false
    }

    private func compactContext() async {
        isCompacting = true
        do {
            _ = try await rpcClient.context.compact(sessionId: sessionId)
            isCompacting = false
            dismiss()
        } catch {
            errorMessage = "Failed to compact context: \(error.localizedDescription)"
            isCompacting = false
        }
    }

}
