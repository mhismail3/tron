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
    @State private var isRetaining = false
    @State private var showClearPopover = false
    @State private var showCompactPopover = false
    @State private var showRetainPopover = false
    @State private var errorMessage: String?

    private var hasMessages: Bool {
        !snapshot.messages.isEmpty
    }

    /// Global rules (from ~/.tron/)
    private var globalRules: LoadedRules? {
        guard let rules = snapshot.rules else { return nil }
        let globalFiles = rules.files.filter { $0.level == .global }
        guard !globalFiles.isEmpty else { return nil }
        return LoadedRules(
            files: globalFiles,
            totalFiles: globalFiles.count,
            tokens: rules.tokens // token count is aggregate; we show it on global only as approximation
        )
    }

    /// Project rules (project + directory scoped)
    private var projectRules: LoadedRules? {
        guard let rules = snapshot.rules else { return nil }
        let projectFiles = rules.files.filter { $0.level == .project || $0.level == .directory }
        guard !projectFiles.isEmpty else { return nil }
        return LoadedRules(
            files: projectFiles,
            totalFiles: projectFiles.count,
            tokens: 0 // no separate token count available for project subset
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
                                HStack {
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
                                HStack {
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
            ToolbarItemGroup(placement: .topBarLeading) {
                clearButton
                compactButton
            }
            ToolbarItem(placement: .principal) {
                Text("Context")
                    .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(.tronCyan)
            }
            ToolbarItem(placement: .topBarTrailing) {
                retainButton
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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

    private var hasGlobalContent: Bool {
        globalRules != nil || !(skillStore?.globalSkills ?? []).isEmpty
    }

    private var hasProjectContent: Bool {
        projectRules != nil || !(skillStore?.projectSkills ?? []).isEmpty
    }

    private var hasSessionContent: Bool {
        !displayedAddedSkills.isEmpty
    }

    // MARK: - Toolbar Buttons

    private var clearButton: some View {
        Button {
            showClearPopover = true
        } label: {
            HStack(spacing: 4) {
                if isClearing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.tronError)
                } else {
                    Image(systemName: "trash")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                }
            }
            .foregroundStyle(hasMessages && !readOnly ? .tronError : .tronTextMuted)
        }
        .disabled(isClearing || !hasMessages || readOnly)
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
        Button {
            showCompactPopover = true
        } label: {
            HStack(spacing: 4) {
                if isCompacting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.tronSlate)
                } else {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                }
            }
            .foregroundStyle(hasMessages && !readOnly ? .tronSlate : .tronTextMuted)
        }
        .disabled(isCompacting || !hasMessages || readOnly)
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

    private var retainButton: some View {
        Button {
            showRetainPopover = true
        } label: {
            HStack(spacing: 4) {
                if isRetaining {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.tronPink)
                } else {
                    Image(systemName: "brain")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                }
                Text("Retain")
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
            }
            .foregroundStyle(!readOnly && !isRetaining ? .tronPink : .tronTextMuted)
        }
        .disabled(isRetaining || readOnly)
        .popover(isPresented: $showRetainPopover, arrowEdge: .top) {
            GlassActionSheet(
                actions: [
                    GlassAction(
                        title: "Retain Memory",
                        icon: "brain",
                        color: .tronPink,
                        role: .default
                    ) {
                        showRetainPopover = false
                        Task { await retainMemory() }
                    },
                    GlassAction(
                        title: "Cancel",
                        icon: nil,
                        color: .tronTextMuted,
                        role: .cancel
                    ) {
                        showRetainPopover = false
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

    private func retainMemory() async {
        isRetaining = true
        do {
            _ = try await rpcClient.misc.retainMemory(sessionId: sessionId)
            isRetaining = false
        } catch {
            errorMessage = "Failed to retain memory: \(error.localizedDescription)"
            isRetaining = false
        }
    }
}
