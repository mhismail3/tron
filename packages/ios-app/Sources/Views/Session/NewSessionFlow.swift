import SwiftUI

// MARK: - New Session Creation

struct NewSessionCreated: Equatable, Sendable {
    let sessionId: String
    let workspaceId: String
    let model: String
    let workingDirectory: String
    let source: String?
}

struct NewSessionCreateIntent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case chat
        case project
    }

    let kind: Kind
    let workingDirectory: String
    let model: String
    let title: String?
    let source: String?
    let useWorktree: Bool?

    static func chat(workspace: String, model: String) -> NewSessionCreateIntent? {
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty, !model.isEmpty else { return nil }
        return NewSessionCreateIntent(
            kind: .chat,
            workingDirectory: workspace,
            model: model,
            title: "Chat",
            source: "chat",
            useWorktree: nil
        )
    }

    static func project(
        workingDirectory: String,
        model: String,
        useWorktreeOverride: Bool?
    ) -> NewSessionCreateIntent? {
        let workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workingDirectory.isEmpty, !model.isEmpty else { return nil }
        return NewSessionCreateIntent(
            kind: .project,
            workingDirectory: workingDirectory,
            model: model,
            title: nil,
            source: nil,
            useWorktree: useWorktreeOverride
        )
    }
}

enum NewSessionChatStartAction: Equatable, Sendable {
    case create(NewSessionCreateIntent)
    case selectWorkspace
    case waitForModel

    static func resolve(quickWorkspace: String, model: String) -> NewSessionChatStartAction {
        let workspace = quickWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return .selectWorkspace }
        guard let intent = NewSessionCreateIntent.chat(workspace: workspace, model: model) else {
            return .waitForModel
        }
        return .create(intent)
    }
}

enum NewSessionCloneTarget: Equatable, Sendable {
    static func destinationWorkspace(from selectedWorkspace: String) -> String? {
        let selectedWorkspace = selectedWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedWorkspace.isEmpty else { return nil }
        return selectedWorkspace
    }
}

enum NewSessionModelCardValue: Equatable, Sendable {
    static func resolve(
        selectedModel: String,
        availableModels: [ModelInfo],
        isLoadingModels: Bool
    ) -> String {
        if isLoadingModels && selectedModel.isEmpty {
            return "Loading..."
        }
        if selectedModel.isEmpty {
            return "Unavailable"
        }
        if let model = availableModels.first(where: { $0.id == selectedModel }) {
            return model.name
        }
        return selectedModel.shortModelName
    }
}

enum NewSessionWorktreeVisibility: Equatable, Sendable {
    static func whileChecking(currentIsGitRepo: Bool, nextWorkspace: String) -> Bool {
        let nextWorkspace = nextWorkspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextWorkspace.isEmpty else { return false }
        return currentIsGitRepo
    }
}

enum NewSessionMode: String, Identifiable, Sendable {
    case chat
    case project
    case clone
    case importClaude

    var id: String { rawValue }
}

// MARK: - New Session Flow

@available(iOS 26.0, *)
struct NewSessionFlow: View {
    let rpcClient: RPCClient
    let defaultModel: String
    let eventStoreManager: EventStoreManager
    let selectedSessionId: String?
    let onSessionCreated: (NewSessionCreated) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies

    @State private var workingDirectory = ""
    @State private var selectedModel: String = ""
    @State private var creatingMode: NewSessionMode?
    @State private var errorMessage: String?
    @State private var showWorkspaceSelector = false
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var showModelPicker = false

    // Clone repository sheet
    @State private var selectedReasoningLevel = "medium"
    @State private var showCloneSheet = false

    // Import from Claude Code
    @State private var showImportFlow = false

    // Per-session worktree override
    /// Global isolation mode fetched from server settings ("always" | "lazy" | "never").
    /// Drives the inferred default state of the worktree toggle.
    @State private var globalIsolationMode: String = "always"
    /// Whether the chosen workspace is inside a git repo (decides toggle visibility).
    @State private var workspaceIsGitRepo: Bool = false
    /// User's explicit override. `nil` until they touch the toggle -
    /// kept `nil` so we can distinguish "untouched, inherit global" from
    /// "user explicitly chose default value".
    @State private var useWorktreeOverride: Bool? = nil
    /// In-flight git-repo lookup. Cancelled when workspace changes.
    @State private var gitRepoCheckTask: Task<Void, Never>?

    private var isCreating: Bool {
        creatingMode != nil
    }

    private var canCreateProject: Bool {
        !isCreating && NewSessionCreateIntent.project(
            workingDirectory: workingDirectory,
            model: selectedModel,
            useWorktreeOverride: useWorktreeOverride
        ) != nil
    }

    private var cloneDestinationWorkspace: String? {
        NewSessionCloneTarget.destinationWorkspace(from: workingDirectory)
    }

    private var canCloneIntoWorkspace: Bool {
        !isCreating && cloneDestinationWorkspace != nil && !selectedModel.isEmpty
    }

    /// Inferred default state of the worktree toggle, derived from the global
    /// isolation mode. "always" and "lazy" both default to ON; "never" -> OFF.
    private var inferredWorktreeDefault: Bool {
        globalIsolationMode != "never"
    }

    /// Effective on/off state shown in the toggle UI (override wins, else inferred).
    private var effectiveUseWorktreeForUI: Bool {
        useWorktreeOverride ?? inferredWorktreeDefault
    }

    private var useWorktreeCaption: String {
        if effectiveUseWorktreeForUI {
            return "Runs on a session worktree branch."
        } else {
            return "Runs directly on the current branch."
        }
    }

    private var quickWorkspace: String {
        resolveQuickSessionWorkspace(
            setting: dependencies.quickSessionWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: selectedSessionId,
            sessions: eventStoreManager.sessions,
            sortedSessions: eventStoreManager.sortedSessions
        )
    }

    private var quickWorkspaceDisplay: String {
        guard !quickWorkspace.isEmpty else { return "Needs workspace" }
        return URL(fileURLWithPath: quickWorkspace).lastPathComponent
    }

    /// Unique workspace paths from recent sessions, ordered by most recent activity.
    private var recentWorkspaces: [(path: String, name: String)] {
        CachedSession.recentWorkspaces(from: eventStoreManager.sortedSessions)
    }

    private var cloneCaption: String {
        guard let cloneDestinationWorkspace else {
            return "Choose a workspace before cloning."
        }
        return "Optional. Clone into \(cloneDestinationWorkspace.abbreviatingHomeDirectory), then start in the repo."
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 22) {
                    HStack(spacing: 12) {
                        NewSessionShortcutButton(
                            icon: "bubble.left.and.bubble.right.fill",
                            title: "Quick Chat",
                            caption: quickWorkspaceDisplay,
                            color: .tronCyan,
                            isBusy: creatingMode == .chat,
                            isDisabled: isCreating || (!quickWorkspace.isEmpty && selectedModel.isEmpty),
                            action: startChatSession
                        )

                        NewSessionShortcutButton(
                            icon: "square.and.arrow.down",
                            title: "Import",
                            caption: "Claude Code",
                            color: .tronCoral,
                            isDisabled: isCreating,
                            action: { showImportFlow = true }
                        )
                    }

                    NewSessionDivider()

                    workspaceSetup

                    if let errorMessage {
                        NewSessionErrorCard(message: errorMessage) {
                            self.errorMessage = nil
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetCloseButton(color: .tronEmerald)
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "New Session", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startProjectSession(workingDirectory: workingDirectory, mode: .project)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                            Text("Create")
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    }
                    .foregroundStyle(canCreateProject ? .tronEmerald : .tronTextDisabled)
                    .disabled(!canCreateProject)
                }
            }
            .sheet(isPresented: $showWorkspaceSelector) {
                WorkspaceSelector(
                    rpcClient: rpcClient,
                    selectedPath: $workingDirectory
                )
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    models: availableModels,
                    currentModelId: selectedModel,
                    reasoningLevel: selectedReasoningLevel,
                    onSelect: { model in
                        selectedModel = model.id
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .reasoningLevelAction)) { notification in
                guard let level = notification.object as? String else { return }
                selectedReasoningLevel = level
            }
            .sheet(isPresented: $showImportFlow) {
                ImportSessionFlow(
                    rpcClient: rpcClient,
                    onImported: { sessionId, workingDirectory, model in
                        onSessionCreated(NewSessionCreated(
                            sessionId: sessionId,
                            workspaceId: workingDirectory,
                            model: model,
                            workingDirectory: workingDirectory,
                            source: nil
                        ))
                    }
                )
            }
            .sheet(isPresented: $showCloneSheet) {
                CloneRepoSheet(
                    rpcClient: rpcClient,
                    initialDestinationPath: cloneDestinationWorkspace,
                    onCloned: { clonedPath in
                        workingDirectory = clonedPath
                        startProjectSession(workingDirectory: clonedPath, mode: .clone)
                    }
                )
            }
            .task {
                await loadModels()
                await loadGlobalIsolationMode()
            }
            .onChange(of: rpcClient.connectionState) { oldState, newState in
                if newState.isConnected && !oldState.isConnected {
                    _ = Task {
                        await loadModels()
                        await loadGlobalIsolationMode()
                    }
                }
            }
            .onChange(of: workingDirectory) { _, newPath in
                // Workspace changed: cancel any in-flight git-repo check and
                // reset the user's override so it mirrors the inferred default
                // for the new workspace. Keep the current worktree-card
                // visibility while probing a non-empty path so git-to-git
                // workspace switches do not flicker off and back on.
                gitRepoCheckTask?.cancel()
                useWorktreeOverride = nil
                let trimmedPath = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
                withAnimation(.smooth(duration: 0.22)) {
                    workspaceIsGitRepo = NewSessionWorktreeVisibility.whileChecking(
                        currentIsGitRepo: workspaceIsGitRepo,
                        nextWorkspace: trimmedPath
                    )
                }
                guard !trimmedPath.isEmpty else { return }
                gitRepoCheckTask = Task {
                    let result = (try? await rpcClient.worktree.isGitRepo(trimmedPath)) ?? false
                    if !Task.isCancelled {
                        await MainActor.run {
                            withAnimation(.smooth(duration: 0.22)) {
                                workspaceIsGitRepo = result
                            }
                        }
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isCreating)
        .tint(.tronEmerald)
    }

    // MARK: - Sections

    private var workspaceSetup: some View {
        VStack(spacing: 12) {
            if !recentWorkspaces.isEmpty {
                recentWorkspaceChips
            }

            NewSessionSetupCard(
                icon: "folder.fill",
                title: "Workspace",
                value: workingDirectory.isEmpty ? "Select" : displayWorkspacePath,
                caption: "Directory where the agent will operate.",
                color: .tronEmerald,
                isDisabled: isCreating,
                action: { showWorkspaceSelector = true }
            )

            NewSessionSetupCard(
                icon: "cpu",
                title: "Model",
                value: selectedModelValue,
                caption: modelCaption,
                color: .tronPurple,
                isBusy: isLoadingModels && selectedModel.isEmpty,
                isDisabled: isCreating,
                action: { showModelPicker = true }
            )

            if workspaceIsGitRepo {
                NewSessionWorktreeCard(
                    isOn: Binding(
                        get: { effectiveUseWorktreeForUI },
                        set: { useWorktreeOverride = $0 }
                    ),
                    caption: useWorktreeCaption,
                    isDisabled: isCreating
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            NewSessionSetupCard(
                icon: "arrow.down.doc.fill",
                title: "Clone GitHub",
                value: "Optional",
                caption: cloneCaption,
                color: .tronTeal,
                isBusy: creatingMode == .clone,
                isDisabled: !canCloneIntoWorkspace,
                action: { showCloneSheet = true }
            )
        }
        .padding(.top, 2)
    }

    private var recentWorkspaceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentWorkspaces, id: \.path) { workspace in
                    let isSelected = workingDirectory == workspace.path
                    Button {
                        workingDirectory = workspace.path
                    } label: {
                        Text(workspace.name)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .chipStyle(
                        .tronEmerald,
                        tintOpacity: isSelected ? 0.3 : 0.15
                    )
                    .disabled(isCreating)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
        .contentMargins(.horizontal, 20)
        .padding(.horizontal, -20)
    }

    // MARK: - Computed Properties

    private var selectedModelValue: String {
        NewSessionModelCardValue.resolve(
            selectedModel: selectedModel,
            availableModels: availableModels,
            isLoadingModels: isLoadingModels
        )
    }

    /// Workspace path formatted for display (truncates /Users/<user>/ to ~/).
    private var displayWorkspacePath: String {
        workingDirectory.abbreviatingHomeDirectory
    }

    private var modelDescription: String {
        if let model = availableModels.first(where: { $0.id == selectedModel }),
           let desc = model.modelDescription {
            return desc
        }
        return ""
    }

    private var modelCaption: String {
        let reasoning = "Reasoning: \(reasoningLevelLabel(selectedReasoningLevel))"
        guard !modelDescription.isEmpty else { return reasoning }
        return "\(modelDescription) - \(reasoning)"
    }

    private func reasoningLevelLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra High"
        case "max": return "Max"
        default: return level.capitalized
        }
    }

    // MARK: - Actions

    private func startChatSession() {
        errorMessage = nil
        switch NewSessionChatStartAction.resolve(quickWorkspace: quickWorkspace, model: selectedModel) {
        case .create(let intent):
            createSession(intent, mode: .chat)
        case .selectWorkspace:
            showWorkspaceSelector = true
        case .waitForModel:
            errorMessage = "Models are still loading."
        }
    }

    private func startProjectSession(workingDirectory: String, mode: NewSessionMode) {
        errorMessage = nil
        guard let intent = NewSessionCreateIntent.project(
            workingDirectory: workingDirectory,
            model: selectedModel,
            useWorktreeOverride: useWorktreeOverride
        ) else {
            if selectedModel.isEmpty {
                errorMessage = "Models are still loading."
            } else {
                errorMessage = "Choose a workspace before creating."
            }
            return
        }
        createSession(intent, mode: mode)
    }

    private func loadModels() async {
        isLoadingModels = true

        // Ensure connection is established.
        await rpcClient.connect()
        if !rpcClient.isConnected {
            try? await Task.sleep(for: .milliseconds(100))
        }

        do {
            let models = try await rpcClient.model.list()
            await MainActor.run {
                availableModels = models

                // Set default model - prefer the passed defaultModel if valid,
                // otherwise use the first recommended model.
                if let defaultMatch = models.first(where: { $0.id == defaultModel }) {
                    selectedModel = defaultMatch.id
                } else if let recommended = models.first(where: { $0.recommended == true && $0.isAnthropic }) {
                    selectedModel = recommended.id
                } else if let first = models.first {
                    selectedModel = first.id
                }

                isLoadingModels = false
            }
        } catch {
            await MainActor.run {
                selectedModel = defaultModel.isEmpty ? (availableModels.first?.id ?? "") : defaultModel
                isLoadingModels = false
            }
        }
    }

    private func loadGlobalIsolationMode() async {
        guard let settings = try? await rpcClient.settings.get() else { return }
        await MainActor.run {
            globalIsolationMode = settings.isolationMode
        }
    }

    private func createSession(_ intent: NewSessionCreateIntent, mode: NewSessionMode) {
        creatingMode = mode
        errorMessage = nil

        Task {
            do {
                let result = try await rpcClient.session.create(
                    workingDirectory: intent.workingDirectory,
                    model: intent.model,
                    title: intent.title,
                    source: intent.source,
                    useWorktree: intent.useWorktree
                )

                // Persist non-default reasoning level to the new session.
                if selectedReasoningLevel != "medium" {
                    _ = try? await rpcClient.model.setReasoningLevel(result.sessionId, level: selectedReasoningLevel)
                }

                await MainActor.run {
                    onSessionCreated(NewSessionCreated(
                        sessionId: result.sessionId,
                        workspaceId: intent.workingDirectory,
                        model: result.model,
                        workingDirectory: intent.workingDirectory,
                        source: intent.source
                    ))
                    creatingMode = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    creatingMode = nil
                }
            }
        }
    }
}

// MARK: - Cards

@available(iOS 26.0, *)
private struct NewSessionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.tronTextMuted.opacity(0.22))
            .frame(height: 1)
            .padding(.horizontal, 2)
    }
}

@available(iOS 26.0, *)
private struct NewSessionCardIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16)
    }
}

@available(iOS 26.0, *)
private struct NewSessionCardCaption: View {
    let caption: String
    var font: Font = TronTypography.codeCaption

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear
                .frame(width: 16, height: 1)

            Text(caption)
                .font(font)
                .foregroundStyle(.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@available(iOS 26.0, *)
private struct NewSessionShortcutButton: View {
    let icon: String
    let title: String
    let caption: String
    let color: Color
    var isBusy: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    NewSessionCardIcon(systemName: icon, color: color)

                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Spacer(minLength: 0)

                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(color)
                    }
                }

                NewSessionCardCaption(
                    caption: caption,
                    font: TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium)
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isBusy)
        .glassEffect(
            .regular.tint(color.opacity(0.16)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .opacity(isDisabled && !isBusy ? 0.62 : 1)
    }
}

@available(iOS 26.0, *)
private struct NewSessionSetupCard: View {
    let icon: String
    let title: String
    let value: String
    let caption: String
    let color: Color
    var isBusy: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    NewSessionCardIcon(systemName: icon, color: color)

                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 10)

                    if isBusy {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(color)
                    } else {
                        Text(value)
                            .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                            .foregroundStyle(isDisabled ? .tronTextDisabled : color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .truncationMode(.middle)
                    }
                }

                NewSessionCardCaption(caption: caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .glassEffect(
            .regular.tint(color.opacity(0.15)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .opacity(isDisabled ? 0.62 : 1)
    }
}

@available(iOS 26.0, *)
private struct NewSessionWorktreeCard: View {
    @Binding var isOn: Bool
    let caption: String
    var isDisabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                NewSessionCardIcon(systemName: "arrow.triangle.branch", color: .tronAmber)

                Text("Worktree")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(.tronAmber)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 10)

                Text(isOn ? "Isolated" : "Current")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                    .foregroundStyle(isDisabled ? .tronTextDisabled : .tronAmber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(.tronAmber)
                    .disabled(isDisabled)
            }

            NewSessionCardCaption(caption: caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.tint(Color.tronAmber.opacity(0.15)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .opacity(isDisabled ? 0.62 : 1)
    }
}

@available(iOS 26.0, *)
private struct NewSessionErrorCard: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronError)

            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3))
                    .foregroundStyle(.tronError)

                Button("Dismiss", action: onDismiss)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
            }

            Spacer()
        }
        .padding(12)
        .glassEffect(
            .regular.tint(Color.tronError.opacity(0.22)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
