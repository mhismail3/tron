import SwiftUI

struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var workspace = ""
    @State private var selectedServerID: String?
    @State private var useDefaultWorkspace = true
    @State private var selectedModel: ModelRef?
    @State private var configuredModel: ModelRef?
    @State private var sourceControl = SessionSourceControlSelection.existing
    @State private var gitInspection: GitInspection?
    @State private var gitInspectionFailed = false
    @State private var showBrowser = false
    @State private var showServers = false
    @State private var showSourceControl = false
    @State private var showModels = false
    @State private var trustInspection: JSONValue?
    @State private var configurationOwner = NewSessionConfigurationOwner()
    @State private var creationOwner = NewSessionCreationOwner()
    let onCreated: (AppModel.SessionNavigationRoute) -> Void

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    if !quickSelections.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickSelections) { shortcut in
                                    Button {
                                        selectQuickSelection(shortcut)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(shortcut.projectName)
                                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                                .foregroundStyle(Color.tronAccentText)
                                                .lineLimit(1)
                                            Text(shortcut.serverName)
                                                .font(TronTypography.secondaryDescription)
                                                .foregroundStyle(Color.tronTextSecondary)
                                                .lineLimit(1)
                                        }
                                        .frame(minWidth: 92, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                    }
                                    .buttonStyle(.plain)
                                    .glassEffect(
                                        .regular.tint(Color.tronEmerald.opacity(workspace == shortcut.path && activeProfileID == shortcut.serverID ? 0.30 : 0.15)).interactive(),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(shortcut.projectName), \(shortcut.serverName)")
                                    .accessibilityValue(workspace == shortcut.path && activeProfileID == shortcut.serverID ? "Selected" : "")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollClipDisabled()
                    }

                    setupCard(
                        icon: "desktopcomputer",
                        title: "Server",
                        value: selectedServer?.label ?? "Select",
                        caption: selectedServer.map { "\($0.host):\($0.port)" } ?? "Choose the server for this new session.",
                        accent: .tronEmerald
                    ) { showServers = true }

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
                        value: sourceControl.displayName,
                        caption: sourceControl.displayDescription,
                        accent: .tronTeal
                    ) { showSourceControl = true }

                    setupCard(
                        icon: "cpu",
                        title: "Model",
                        value: selectedModel?.displayName ?? "Default",
                        caption: selectedModel?.displayDescription ?? "Use the current agent default.",
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
                        TronToolbarTextLabel(
                            creationActionTitle,
                            systemImage: "checkmark",
                            isWorking: creating || configurationLoading
                        )
                        .tronToolbarAction()
                    }
                    .disabled(creating || !configurationReady)
                }
            }
            .tronManagedSheet(isPresented: $showBrowser, identity: "new-session.workspace") {
                WorkspaceBrowser(shortcuts: recentWorkspaces, initialPath: workspace) { value in
                    workspace = value
                    useDefaultWorkspace = false
                }
            }
            .tronManagedSheet(isPresented: $showSourceControl, identity: "new-session.source-control") {
                NewSessionSourceControlSheet(
                    selection: $sourceControl,
                    inspection: gitInspection,
                    inspectionFailed: gitInspectionFailed
                )
                .tronTopBlur(.sheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
            }
            .tronManagedSheet(isPresented: $showServers, identity: "new-session.servers") {
                NavigationStack {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            TronSettingsGroup("Paired Servers", detail: "New sessions will be created on the selected server.") {
                                VStack(spacing: 0) {
                                    ForEach(Array(pairedServers.enumerated()), id: \.element.id) { index, profile in
                                        if index > 0 { TronSettingsDivider() }
                                        Button {
                                            selectServer(profile)
                                        } label: {
                                            TronValueRow(
                                                icon: profile.id == activeProfileID ? "checkmark.circle.fill" : "desktopcomputer",
                                                title: profile.label,
                                                detail: profile.isEnabled
                                                    ? "\(profile.host):\(profile.port)"
                                                    : "Disabled · \(profile.host):\(profile.port)",
                                                accent: profile.id == activeProfileID ? .tronEmerald : .tronCyan
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!profile.isEnabled)
                                    }
                                }
                            }
                        }
                        .padding(20)
                    }
                    .tronScrollEdgeChrome()
                    .tronNavigationTitle("Select Server")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { showServers = false } label: {
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
            .tronManagedSheet(isPresented: $showModels, identity: "new-session.models") {
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
            .task(id: PresentationActivityTaskID(
                source: NewSessionConfigurationLoadID(
                    profileID: activeProfileID,
                    workspace: workspace,
                    trustInvalidationGeneration: model.trustRevision,
                    profileRevision: model.profileRevision
                ),
                presentationActive: presentationActivity.allowsPresentationPublication
            )) {
                guard presentationActivity.allowsPresentationPublication else { return }
                if selectedServerID == nil {
                    selectedServerID = model.profiles.selected?.id
                }
                guard let profileID = selectedServerID,
                      model.profiles.selected?.id == profileID else {
                    // A quick project selection can target another server. Do
                    // not issue settings, trust, or Git reads through the old
                    // connection while Gateway is switching profiles.
                    return
                }
                configurationOwner.begin(profileID: profileID, workspace: workspace)
                trustInspection = nil
                gitInspection = nil
                gitInspectionFailed = false
                selectedModel = nil
                configuredModel = nil
                sourceControl = .existing
                if workspace.isEmpty, useDefaultWorkspace,
                   let defaultWorkspace = model.defaultWorkspace, !defaultWorkspace.isEmpty {
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
                    trustReady = await inspectTrust(cwd: requestedWorkspace, profileID: profileID)
                }
                let inspectedGit: GitInspection?
                let gitFailed: Bool
                if requestedWorkspace.isEmpty {
                    inspectedGit = nil
                    gitFailed = false
                } else {
                    do {
                        inspectedGit = try await model.gatewayDiagnostics.inspectGit(path: requestedWorkspace)
                        gitFailed = false
                    } catch {
                        // A profile transition can close the old socket while
                        // this read is suspended. The new profile will rerun
                        // the load after its revision is published.
                        inspectedGit = nil
                        gitFailed = true
                    }
                }
                guard model.profiles.selected?.id == profileID,
                      selectedServerID == profileID,
                      workspace == requestedWorkspace else { return }
                gitInspection = inspectedGit
                gitInspectionFailed = gitFailed
                let loadedSettings = await settingsReady
                guard model.profiles.selected?.id == profileID,
                      selectedServerID == profileID,
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
                        .font(TronTypography.secondaryDescription)
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

    private var pairedServers: [GatewayProfile] {
        _ = model.profileRevision
        return model.profiles.profiles
    }

    private var activeProfileID: String? {
        selectedServerID ?? model.profiles.selected?.id
    }

    private var selectedServer: GatewayProfile? {
        guard let activeProfileID else { return nil }
        return model.profiles.profiles.first(where: { $0.id == activeProfileID })
    }

    private func selectServer(_ profile: GatewayProfile) {
        guard profile.isEnabled else { return }
        selectedServerID = profile.id
        workspace = ""
        useDefaultWorkspace = false
        trustInspection = nil
        gitInspection = nil
        gitInspectionFailed = false
        selectedModel = nil
        configuredModel = nil
        sourceControl = .existing
        showServers = false
        guard model.profiles.selected?.id != profile.id else { return }
        Task { await model.switchGateway(profile) }
    }

    private var needsTrust: Bool {
        guard let value = trustInspection?.objectValue else { return false }
        return value["requiresDecision"]?.boolValue == true && value["effectiveDecision"] == .null
    }

    private var quickSelections: [NewSessionQuickSelection] {
        let profilesByID = Dictionary(uniqueKeysWithValues: pairedServers.map { ($0.id, $0) })
        var seen = Set<String>()
        return model.visibleSessions.compactMap { session in
            let profileID = session.gatewayProfileID ?? model.profiles.selected?.id
            guard let profileID,
                  let profile = profilesByID[profileID],
                  profile.isEnabled,
                  seen.insert("\(profileID)|\(session.cwd)").inserted else { return nil }
            return NewSessionQuickSelection(
                path: session.cwd,
                projectName: session.workspaceName,
                serverID: profileID,
                serverName: profile.label
            )
        }
    }

    private var recentWorkspaces: [WorkspaceShortcut] {
        guard let profileID = activeProfileID else { return [] }
        var seen = Set<String>()
        return model.visibleSessions.compactMap { session in
            guard session.gatewayProfileID == profileID ||
                    (session.gatewayProfileID == nil && model.profiles.selected?.id == profileID),
                  seen.insert(session.cwd).inserted else { return nil }
            return WorkspaceShortcut(path: session.cwd, title: session.workspaceName, icon: "clock.arrow.circlepath")
        }
    }

    private func selectQuickSelection(_ shortcut: NewSessionQuickSelection) {
        guard let profile = pairedServers.first(where: { $0.id == shortcut.serverID }), profile.isEnabled else { return }
        let shouldSwitch = model.profiles.selected?.id != profile.id
        selectedServerID = profile.id
        workspace = shortcut.path
        useDefaultWorkspace = false
        trustInspection = nil
        gitInspection = nil
        gitInspectionFailed = false
        selectedModel = nil
        configuredModel = nil
        sourceControl = .existing
        guard shouldSwitch else { return }
        Task { await model.switchGateway(profile) }
    }

    private func inspectTrust(cwd: String, profileID: String) async -> Bool {
        guard let target = TrustTarget(cwd: cwd) else { return false }
        do {
            let inspection = try await model.inspectTrust(target: target)
            guard workspace == cwd,
                  selectedServerID == profileID,
                  model.profiles.selected?.id == profileID else { return false }
            trustInspection = inspection
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard workspace == cwd,
                  selectedServerID == profileID,
                  model.profiles.selected?.id == profileID else { return false }
            model.presentError(error)
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
            model.presentError(error)
        }
    }

    private var configurationReady: Bool {
        configurationOwner.permitsCreation(
            profileID: activeProfileID,
            workspace: workspace,
            requiresTrust: needsTrust
        ) && sourceControl.isAdmissible(for: gitInspection)
    }

    private var configurationLoading: Bool {
        configurationOwner.isLoading(
            profileID: activeProfileID,
            workspace: workspace
        ) || (sourceControl.mode != .existingCheckout && !workspace.isEmpty && gitInspection == nil && !gitInspectionFailed)
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
        let requestedSourceControl = sourceControl
        Task { await create(cwd: cwd, sourceControl: requestedSourceControl, modelOverride: modelOverride) }
    }

    private func create(
        cwd: String,
        sourceControl: SessionSourceControlSelection,
        modelOverride: ModelRef?
    ) async {
        defer { creationOwner.finish() }
        do {
            let route = try await model.createSession(cwd: cwd, sourceControl: sourceControl)
            guard model.ownsNavigationRoute(route) else {
                model.presentError("The new session was created, but this navigation request is no longer current.")
                dismiss()
                return
            }
            onCreated(route.withInitialModel(modelOverride))
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            model.presentError(error)
        }
    }

    private func abbreviated(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.count > 3 ? "…/" + components.suffix(2).joined(separator: "/") : path
    }
}
