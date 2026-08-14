import SwiftUI
import UniformTypeIdentifiers

struct SessionShellView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewSession = false
    @State private var newSessionDetent: PresentationDetent = .medium
    @State private var showSettings = false
    @State private var showImport = false
    @State private var search = ""
    @State private var showingSearch = false
    @State private var presentedSession: AppModel.SessionNavigationRoute?
    @State private var sessionToDelete: SessionSummary?
    @State private var sessionToRename: SessionSummary?
    @State private var renameName = ""
    @State private var collapsedWorkspaces = Set<String>()

    var body: some View {
        dashboardNavigation
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet {
                present(AppModel.SessionNavigationRoute(sessionID: $0, editorText: nil))
            }
                .tronTopBlur(.sheet)
                .presentationDetents([.medium, .large], selection: $newSessionDetent)
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().presentationDragIndicator(.hidden)
        }
        .fileImporter(
            isPresented: $showImport,
            allowedContentTypes: [.json, .plainText, .data],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .confirmationDialog(
            "Delete \(sessionToDelete?.title ?? "this session")?",
            isPresented: deleteConfirmationPresented,
            presenting: sessionToDelete,
            actions: deleteConfirmationActions,
            message: { _ in
                Text("This removes the canonical session from the Mac and cannot be undone.")
            }
        )
        .alert("Rename Session", isPresented: renameConfirmationPresented, presenting: sessionToRename) { session in
            TextField("Session name", text: $renameName)
            Button("Save") { rename(session) }
                .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { sessionToRename = nil }
        }
        .gatewayGlobalSheets()
    }

    private var dashboardNavigation: some View {
        NavigationStack {
            dashboardScreen
        }
        .tint(Color.tronEmerald)
    }

    private var dashboardScreen: some View {
        ZStack(alignment: .bottomTrailing) {
            sessionList
            TronTopBlurOverlay(style: .dashboard)
            newSessionButton
        }
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { dashboardToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showingSearch {
                    TronSearchBar(text: $search, prompt: "Search sessions", focusOnAppear: true)
                        .padding(.horizontal, TronSpacing.section)
                        .padding(.vertical, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refreshSessions() }
            .navigationDestination(item: $presentedSession) { route in
                ChatView(
                    sessionID: route.sessionID,
                    initialEditorText: route.editorText,
                    onForkCreated: present
                )
                .id(route.sessionID)
            }
    }

    private func present(_ route: AppModel.SessionNavigationRoute) {
        if let current = presentedSession,
           let target = model.presentationTarget(for: current.sessionID) {
            model.revokePresentationIntake(target)
        }
        presentedSession = route
    }

    private var newSessionButton: some View {
        Button {
            showNewSession = true
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(TronIconButtonStyle(size: 56))
        .accessibilityLabel("New Session")
        .accessibilityHint("Opens the new session sheet")
        .padding(.trailing, 20)
        .padding(.bottom, 8)
    }

    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Import Session", systemImage: "square.and.arrow.down") { showImport = true }
            } label: {
                Image("TronLogoVector")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 28)
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Open Tron navigation")
        }
        ToolbarItem(placement: .principal) {
            Text("Tron")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                .foregroundStyle(Color.tronEmerald)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    showingSearch.toggle()
                    if !showingSearch { search = "" }
                }
            } label: {
                Image(systemName: showingSearch ? "xmark" : "magnifyingglass")
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel(showingSearch ? "Close session search" : "Search sessions")
            Button("Settings", systemImage: "gearshape") { showSettings = true }
                .tronToolbarAction(accent: .tronEmerald)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let cwd = model.defaultWorkspace
        guard let cwd else {
            model.lastError = "Choose a workspace by creating a session before importing."
            return
        }
        Task {
            do {
                let sessionID = try await model.importSession(from: url, cwd: cwd)
                present(AppModel.SessionNavigationRoute(sessionID: sessionID, editorText: nil))
            }
            catch { model.lastError = error.localizedDescription }
        }
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )
    }

    private var renameConfirmationPresented: Binding<Bool> {
        Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )
    }

    private func beginRename(_ session: SessionSummary) {
        renameName = session.title
        sessionToRename = session
    }

    private func rename(_ session: SessionSummary) {
        let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do { try await model.renameSession(session.id, name: name) }
            catch { model.lastError = error.localizedDescription }
            sessionToRename = nil
        }
    }

    @ViewBuilder
    private func deleteConfirmationActions(_ session: SessionSummary) -> some View {
        Button("Delete Session", role: .destructive) {
            Task {
                do { try await model.deleteSession(session.id) }
                catch { model.lastError = error.localizedDescription }
                sessionToDelete = nil
            }
        }
    }

    private var sessionList: some View {
        List {
            sessionSections
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 38)
        .contentMargins(.top, 6)
        .contentMargins(.bottom, 92)
        .tronCollectionSurface()
        .tronScrollEdgeChrome()
    }

    @ViewBuilder
    private var sessionSections: some View {
        ForEach(workspaceGroups, id: \.key) { group in
            Section {
                if !collapsedWorkspaces.contains(group.key) {
                    ForEach(group.value) { session in
                        sessionButton(session)
                    }
                }
            } header: {
                workspaceHeader(group.key)
            }
        }
    }

    private func sessionButton(_ session: SessionSummary) -> some View {
        return Button {
            present(AppModel.SessionNavigationRoute(sessionID: session.id, editorText: nil))
        } label: {
            HistoricalSessionRow(session: session)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionDashboardLayout.rowInsets)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { sessionToDelete = session }
            Button("Rename", systemImage: "pencil") { beginRename(session) }
                .tint(Color.tronPurple)
        }
    }

    private func workspaceHeader(_ path: String) -> some View {
        let collapsed = collapsedWorkspaces.contains(path)
        let component = URL(fileURLWithPath: path).lastPathComponent
        let title = component.isEmpty ? path : component
        return Button {
            withAnimation(.smooth(duration: 0.18)) {
                if collapsed { collapsedWorkspaces.remove(path) }
                else { collapsedWorkspaces.insert(path) }
            }
        } label: {
            HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
                Image(systemName: collapsed ? "folder" : "folder.fill")
                    .font(.system(size: SessionDashboardLayout.headerIconSize, weight: .semibold))
                    .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .bold))
                    .lineLimit(1)
                Image(systemName: collapsed ? "plus" : "minus")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
            }
            .foregroundStyle(Color.tronEmerald)
            .padding(.leading, SessionDashboardLayout.headerLeadingPadding)
            .padding(.trailing, SessionDashboardLayout.rowContainerHorizontalInset)
            .padding(.top, SessionDashboardLayout.headerTopPadding)
            .padding(.bottom, SessionDashboardLayout.headerBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .listRowInsets(SessionDashboardLayout.headerInsets)
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? "collapsed" : "expanded")
    }

    private var workspaceGroups: [(key: String, value: [SessionSummary])] {
        Dictionary(grouping: model.visibleSessions.filter { session in
            search.isEmpty
                || session.title.localizedCaseInsensitiveContains(search)
                || session.cwd.localizedCaseInsensitiveContains(search)
        }, by: \.cwd)
        .map { (key: $0.key, value: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }
}

private enum SessionDashboardLayout {
    static let rowContainerHorizontalInset: CGFloat = 16
    static let rowContentHorizontalPadding: CGFloat = 12
    static let iconColumnWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 8
    static let headerIconSize: CGFloat = 14
    static let headerTopPadding: CGFloat = 10
    static let headerBottomPadding: CGFloat = 3
    static var headerLeadingPadding: CGFloat {
        rowContainerHorizontalInset + rowContentHorizontalPadding
    }
    static var headerInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    }
    static var rowInsets: EdgeInsets {
        EdgeInsets(
            top: 2,
            leading: rowContainerHorizontalInset,
            bottom: 2,
            trailing: rowContainerHorizontalInset
        )
    }
}

private struct HistoricalSessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            Group {
                if session.phase.isActive {
                    ProgressView().controlSize(.small).tint(.tronEmerald)
                } else {
                    Image(systemName: session.phase == .interrupted ? "exclamationmark.circle" : "circle")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(session.phase == .interrupted ? Color.tronAmber : Color.tronEmerald.opacity(0.82))
                }
            }
            .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)

            Text(session.title)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 10)

            Text(session.relativeActivityDescription())
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(Color.tronTextMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, SessionDashboardLayout.rowContentHorizontalPadding)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .tronGlassSurface(
            accent: .tronEmerald,
            cornerRadius: 12,
            tintOpacity: 0.14,
            interactive: true
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.title), \(session.phase.rawValue), \(session.relativeActivityDescription())")
    }
}

private struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var selectedModel: ModelRef?
    @State private var showBrowser = false
    @State private var showModels = false
    @State private var creating = false
    @State private var trustInspection: JSONValue?
    @State private var configurationOwner = NewSessionConfigurationOwner()
    let onCreated: (String) -> Void

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
                    Button {
                        Task { await create() }
                    } label: {
                        HStack(spacing: 6) {
                            if creating { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "checkmark") }
                            Text(creating ? "Creating" : "Create")
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                    }
                    .disabled(creating || !configurationOwner.permitsCreation(workspace: workspace, requiresTrust: needsTrust))
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
                workspace: workspace,
                trustInvalidationGeneration: model.trustRevision
            )) {
                configurationOwner.begin(workspace: workspace)
                trustInspection = nil
                selectedModel = nil
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
                guard workspace == requestedWorkspace,
                      configurationOwner.admit(
                        workspace: requestedWorkspace,
                        settingsReady: loadedSettings,
                        trustReady: trustReady
                      ) else { return }
                selectedModel = model.configuredDefaultModel(for: settingsTarget)
                    ?? model.preferredAvailableModel(for: .global)
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

    private func create() async {
        guard configurationOwner.permitsCreation(workspace: workspace, requiresTrust: needsTrust) else { return }
        creating = true
        defer { creating = false }
        do {
            let sessionID = try await model.createSession(cwd: workspace)
            if let selectedModel { try await model.setModel(selectedModel, sessionID: sessionID) }
            onCreated(sessionID)
            dismiss()
        } catch { model.lastError = error.localizedDescription }
    }

    private func abbreviated(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.count > 3 ? "…/" + components.suffix(2).joined(separator: "/") : path
    }
}
