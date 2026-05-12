import SwiftUI

// MARK: - Context Detail View (pushed from Agent Control sheet)

/// Shared layout constants that keep section headers and container rows on a
/// single icon / label column in the Context sheet. All numeric values are in
/// SwiftUI points and are resolution-independent, so alignment holds across
/// every supported device (iPhone SE through iPad). `Spacer` absorbs width
/// differences between screens.
///
/// Derivation: container rows sit inside a VStack with `outerPadding` horizontal
/// inset, and each container's header HStack adds another `rowInnerPadding` —
/// so their icons land at `outerPadding + rowInnerPadding` from the screen edge.
/// Standalone section headers (no container background) match that x via
/// `iconColumnLeading`.
///
/// Sibling section views (SystemPromptSection, ToolsSection, RulesSection,
/// CollapsibleSkillsSection) also reference these constants so the alignment
/// cannot drift if any single value is changed.
enum ContextLayout {
    static let outerPadding: CGFloat = 16
    static let rowInnerPadding: CGFloat = 12
    static let iconFrameWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 8
    static var iconColumnLeading: CGFloat { outerPadding + rowInnerPadding }
}

@available(iOS 26.0, *)
struct ContextDetailView: View {
    let engineClient: EngineClient
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

    private var providerAdjustmentTokens: Int {
        snapshot.breakdown.providerAdjustment ?? 0
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
                                HStack(spacing: ContextLayout.iconTextSpacing) {
                                    Image(systemName: "folder.fill")
                                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                                        .foregroundStyle(.tronSlate)
                                        .frame(width: ContextLayout.iconFrameWidth)
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
                                .padding(.horizontal, ContextLayout.rowInnerPadding)
                                .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, compact: false)
                            }
                            if let origin = env.serverOrigin {
                                HStack(spacing: ContextLayout.iconTextSpacing) {
                                    Image(systemName: "network")
                                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                                        .foregroundStyle(.tronSlate)
                                        .frame(width: ContextLayout.iconFrameWidth)
                                    Text("Server Origin")
                                        .font(TronTypography.codeCaption)
                                        .foregroundStyle(.tronTextMuted)
                                    Spacer()
                                    Text(origin)
                                        .font(TronTypography.codeCaption)
                                        .foregroundStyle(.tronTextSecondary)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, ContextLayout.rowInnerPadding)
                                .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, compact: false)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    if snapshot.breakdown.systemPrompt > 0 {
                        SystemPromptSection(
                            tokens: snapshot.breakdown.systemPrompt,
                            content: snapshot.systemPromptContent
                        )
                    }

                    if let memory = snapshot.memory, snapshot.breakdown.memory > 0 {
                        MemorySection(
                            tokens: snapshot.breakdown.memory,
                            memory: memory
                        )
                    }

                    if snapshot.breakdown.tools > 0 {
                        ToolsSection(
                            toolsContent: snapshot.toolsContent,
                            tokens: snapshot.breakdown.tools
                        )
                    }

                    if providerAdjustmentTokens > 0 {
                        providerAdjustmentRow(tokens: providerAdjustmentTokens)
                    }
                }
                .padding(.horizontal, ContextLayout.outerPadding)

                // Global Context
                if hasGlobalContent {
                    sectionHeader("Global Context", icon: "globe")
                        .padding(.top, 12)

                    VStack(spacing: 10) {
                        if let globalRules {
                            RulesSection(
                                rules: globalRules,
                                onFetchContent: { path in
                                    try await engineClient.filesystem.readFile(path: path)
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
                    .padding(.horizontal, ContextLayout.outerPadding)
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
                                    try await engineClient.filesystem.readFile(path: path)
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
                    .padding(.horizontal, ContextLayout.outerPadding)
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
                    .padding(.horizontal, ContextLayout.outerPadding)
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
        HStack(spacing: ContextLayout.iconTextSpacing) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronCyan)
                .frame(width: ContextLayout.iconFrameWidth)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronCyan)
            Spacer()
        }
        .padding(.leading, ContextLayout.iconColumnLeading)
        .padding(.trailing, ContextLayout.outerPadding)
    }

    private func providerAdjustmentRow(tokens: Int) -> some View {
        HStack(spacing: ContextLayout.iconTextSpacing) {
            Image(systemName: "number")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronSlate)
                .frame(width: ContextLayout.iconFrameWidth)
            Text("Provider Tokenizer Delta")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronSlate)
            Spacer()
            Text(TokenFormatter.format(tokens))
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(ContextLayout.rowInnerPadding)
        .sectionFill(.tronSlate, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            _ = try await engineClient.context.clear(sessionId: sessionId, idempotencyKey: .userAction("context.clear"))
        } catch {
            errorMessage = "Failed to clear context: \(error.localizedDescription)"
        }
        isClearing = false
    }

    private func compactContext() async {
        isCompacting = true
        do {
            _ = try await engineClient.context.compact(sessionId: sessionId, idempotencyKey: .userAction("context.compact"))
            isCompacting = false
            dismiss()
        } catch {
            errorMessage = "Failed to compact context: \(error.localizedDescription)"
            isCompacting = false
        }
    }

}
