import SwiftUI

struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var selectedModel: ModelRef?
    @State private var configuredModel: ModelRef?
    @State private var showBrowser = false
    @State private var showModels = false
    @State private var trustInspection: JSONValue?
    @State private var configurationOwner = NewSessionConfigurationOwner()
    @State private var creationOwner = NewSessionCreationOwner()
    let onCreated: (AppModel.SessionNavigationRoute) -> Void

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    if !recentWorkspaces.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recentWorkspaces) { shortcut in
                                    Button {
                                        workspace = shortcut.path
                                    } label: {
                                        Text(shortcut.title)
                                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                            .foregroundStyle(Color.tronAccentText)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    .glassEffect(
                                        .regular.tint(Color.tronEmerald.opacity(workspace == shortcut.path ? 0.30 : 0.15)).interactive(),
                                        in: Capsule()
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollClipDisabled()
                    }

                    setupCard(
                        icon: "folder.fill",
                        title: "Workspace",
                        value: workspace.isEmpty ? "Select" : abbreviated(workspace),
                        caption: "Directory where Tron will operate.",
                        accent: .tronEmerald
                    ) { showBrowser = true }

                    setupCard(
                        icon: "arrow.triangle.branch",
                        title: "Source Control",
                        value: "Use Existing",
                        caption: "Use the selected checkout at its current commit.",
                        accent: .tronTeal
                    ) {}

                    setupCard(
                        icon: "cpu",
                        title: "Model",
                        value: selectedModel?.id ?? "Default",
                        caption: selectedModel.map { "\($0.provider) / \($0.id)" } ?? "Use the current agent default.",
                        accent: .tronPurple
                    ) { showModels = true }

                    if needsTrust {
                        TronSettingsGroup(
                            "Project Trust",
                            detail: "Project resources execute with your Mac user authority. Trust is not a sandbox.",
                            accent: .tronAmber
                        ) {
                            VStack(spacing: 10) {
                                Button("Trust Project") { Task { await trust(true) } }
                                    .buttonStyle(TronActionButtonStyle(role: .primary))
                                Button("Open Without Project Resources") { Task { await trust(false) } }
                                    .buttonStyle(TronActionButtonStyle(role: .destructive))
                            }
                            .padding(12)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "New Session") }
                ToolbarItem(placement: .confirmationAction) {
                    Button { beginCreation() } label: {
                        HStack(spacing: 6) {
                            if creating || configurationLoading {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "checkmark")
                            }
                            Text(creationActionTitle)
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                    }
                    .disabled(creating || !configurationReady)
                }
            }
            .sheet(isPresented: $showBrowser) {
                WorkspaceBrowser(shortcuts: recentWorkspaces, initialPath: workspace) { value in
                    workspace = value
                }
            }
            .sheet(isPresented: $showModels) {
                NavigationStack {
                    ModelPicker(
                        selection: $selectedModel,
                        models: model.providerCatalog(for: .global)?.models.filter(\.available) ?? []
                    )
                        .tronTopBlurSurface()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) { TronSheetTitle(title: "Model") }
                            ToolbarItem(placement: .confirmationAction) {
                                Button { showModels = false } label: {
                                    Image(systemName: "checkmark")
                                        .font(TronTypography.buttonSM)
                                        .foregroundStyle(Color.tronEmerald)
                                }
                                .accessibilityLabel("Done")
                            }
                        }
                }
                .tronTopBlur(.sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
            .task(id: NewSessionConfigurationLoadID(
                profileID: model.profiles.selected?.id,
                workspace: workspace,
                trustInvalidationGeneration: model.trustRevision
            )) {
                let profileID = model.profiles.selected?.id
                configurationOwner.begin(profileID: profileID, workspace: workspace)
                trustInspection = nil
                selectedModel = nil
                configuredModel = nil
                if workspace.isEmpty, let defaultWorkspace = model.defaultWorkspace, !defaultWorkspace.isEmpty {
                    workspace = defaultWorkspace
                    return
                }
                let requestedWorkspace = workspace
                let settingsTarget = requestedWorkspace.isEmpty
                    ? SettingsTarget.global
                    : .project(cwd: requestedWorkspace)
                async let settingsReady = model.refreshSettings(target: settingsTarget)
                let trustReady: Bool
                if requestedWorkspace.isEmpty {
                    trustReady = true
                } else {
                    trustReady = await inspectTrust(cwd: requestedWorkspace)
                }
                let loadedSettings = await settingsReady
                guard model.profiles.selected?.id == profileID,
                      workspace == requestedWorkspace,
                      configurationOwner.admit(
                        profileID: profileID,
                        workspace: requestedWorkspace,
                        settingsReady: loadedSettings,
                        trustReady: trustReady
                      ) else { return }
                configuredModel = model.configuredDefaultModel(for: settingsTarget)
                selectedModel = configuredModel ?? model.preferredAvailableModel(for: .global)
            }
        }
        .interactiveDismissDisabled(creating)
    }

    private func setupCard(
        icon: String,
        title: String,
        value: String,
        caption: String,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .frame(width: 16)
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    Spacer(minLength: 10)
                    Text(value)
                        .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .truncationMode(.middle)
                }
                .foregroundStyle(accent)
                HStack(alignment: .top, spacing: 8) {
                    Color.clear.frame(width: 16, height: 1)
                    Text(caption)
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(Color.tronTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: accent, cornerRadius: 12, tintOpacity: 0.15, interactive: true)
    }

    private var needsTrust: Bool {
        guard let value = trustInspection?.objectValue else { return false }
        return value["requiresDecision"]?.boolValue == true && value["effectiveDecision"] == .null
    }

    private var recentWorkspaces: [WorkspaceShortcut] {
        var seen = Set<String>()
        return model.visibleSessions.compactMap { session in
            guard seen.insert(session.cwd).inserted else { return nil }
            return WorkspaceShortcut(path: session.cwd, title: session.workspaceName, icon: "clock.arrow.circlepath")
        }
    }

    private func inspectTrust(cwd: String) async -> Bool {
        guard let target = TrustTarget(cwd: cwd) else { return false }
        do {
            let inspection = try await model.inspectTrust(target: target)
            guard workspace == cwd else { return false }
            trustInspection = inspection
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard workspace == cwd else { return false }
            model.lastError = error.localizedDescription
            return false
        }
    }

    private func trust(_ value: Bool) async {
        let cwd = workspace
        guard let target = TrustTarget(cwd: cwd) else { return }
        do {
            let inspection = try await model.setTrust(target: target, decision: value)
            guard workspace == cwd else { return }
            trustInspection = inspection
        } catch {
            guard workspace == cwd else { return }
            model.lastError = error.localizedDescription
        }
    }

    private var configurationReady: Bool {
        configurationOwner.permitsCreation(
            profileID: model.profiles.selected?.id,
            workspace: workspace,
            requiresTrust: needsTrust
        )
    }

    private var configurationLoading: Bool {
        configurationOwner.isLoading(
            profileID: model.profiles.selected?.id,
            workspace: workspace
        )
    }

    private var creating: Bool { creationOwner.isCreating }

    private var creationActionTitle: String {
        if creating { return "Creating" }
        if configurationLoading { return "Preparing" }
        return "Create"
    }

    private func beginCreation() {
        guard creationOwner.begin(configurationReady: configurationReady) else { return }
        let cwd = workspace
        let modelOverride = creationOwner.modelOverride(
            selected: selectedModel,
            configured: configuredModel
        )
        Task { await create(cwd: cwd, modelOverride: modelOverride) }
    }

    private func create(cwd: String, modelOverride: ModelRef?) async {
        defer { creationOwner.finish() }
        do {
            let route = try await model.createSession(cwd: cwd)
            let overrideResolution = await applyModelOverride(modelOverride, to: route)
            guard overrideResolution.presentsCreatedRoute,
                  model.ownsNavigationRoute(route) else { return }
            onCreated(route)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            model.lastError = error.localizedDescription
        }
    }

    private func applyModelOverride(
        _ modelOverride: ModelRef?,
        to route: AppModel.SessionNavigationRoute
    ) async -> NewSessionModelOverrideResolution {
        guard let modelOverride else { return .notRequested }
        do {
            try await model.setModel(modelOverride, sessionID: route.sessionID)
            return .applied
        } catch is CancellationError {
            return .cancelled
        } catch {
            model.lastError = "Session created, but the selected model could not be applied: \(error.localizedDescription)"
            return .failed
        }
    }

    private func abbreviated(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.count > 3 ? "…/" + components.suffix(2).joined(separator: "/") : path
    }
}
