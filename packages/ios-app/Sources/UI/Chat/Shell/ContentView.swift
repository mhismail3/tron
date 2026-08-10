import SwiftUI

struct PendingSessionDeepLink: Equatable {
    let sessionId: String
    let scrollTarget: ScrollTarget?
}

/// One compact-width presentation of a session.
///
/// `sessionId` is durable selection state, while `presentationId` is deliberately
/// fresh for every explicit open. Keeping them separate prevents SwiftUI from
/// reusing a popped `navigationDestination` for the same session without
/// starting the replacement `ChatView` lifecycle.
struct CompactSessionRoute: Hashable {
    let sessionId: String
    let presentationId: UUID

    init(sessionId: String, presentationId: UUID = UUID()) {
        self.sessionId = sessionId
        self.presentationId = presentationId
    }
}

struct ChatSessionPresentationIdentity: Hashable {
    let sessionId: String
    let serverSelectionVersion: Int
}

struct ServerOnboardingLaunchRequest: Equatable {
    let prefill: PairedServer?
}

struct DeferredServerOnboardingLaunch: Equatable {
    private(set) var request: ServerOnboardingLaunchRequest?

    mutating func request(prefill server: PairedServer?) {
        request = ServerOnboardingLaunchRequest(prefill: server)
    }

    mutating func consume() -> ServerOnboardingLaunchRequest? {
        defer { request = nil }
        return request
    }
}

func pendingSessionDeepLink(
    sessionId: String?,
    scrollTarget: ScrollTarget?
) -> PendingSessionDeepLink? {
    guard let sessionId else { return nil }
    return PendingSessionDeepLink(sessionId: sessionId, scrollTarget: scrollTarget)
}

func shouldPresentSelectedSession(
    selectedSessionId: String?,
    knownSessionIds: Set<String>
) -> Bool {
    guard let selectedSessionId else { return false }
    return knownSessionIds.contains(selectedSessionId)
}

func makeCompactSessionRoute(sessionId: String?) -> CompactSessionRoute? {
    guard let sessionId else { return nil }
    return CompactSessionRoute(sessionId: sessionId)
}

// MARK: - Content View

struct ContentView: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Convenience accessors
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    private var defaultModel: String { dependencies.defaultModel }
    private var quickSessionWorkspace: String { dependencies.quickSessionWorkspace }

    // Deep link navigation from TronMobileApp
    @Binding var deepLinkSessionId: String?
    @Binding var deepLinkScrollTarget: ScrollTarget?

    @State private var coordinator: ContentViewCoordinator?
    @State private var selectedSessionId: String?
    @State private var compactSessionRoute: CompactSessionRoute?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showNewSessionSheet = false
    @State private var showSettings = false
    @State private var primaryPage: TronPrimaryPage = .sessions
    @State private var workerConsole = WorkerConsoleViewModel()
    @State private var deferredServerOnboardingLaunch = DeferredServerOnboardingLaunch()
    @State private var sessionHandoffError: String?
    @State private var isCreatingAgentSessionHandoff = false

    // Scroll target for deep link navigation (passed to ChatView)
    @State private var currentScrollTarget: ScrollTarget?

    var body: some View {
        mainContent
            .tronScreenBackground()
            .tint(.tronEmerald)
            #if BETA
            .overlay(alignment: .bottomTrailing) {
                Text("BETA")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tronEmerald.opacity(0.5), in: .capsule)
                    .padding(8)
                    .allowsHitTesting(false)
            }
            #endif
            .sheet(isPresented: $showNewSessionSheet) {
                newSessionFlowSheet
            }
            .sheet(isPresented: $showSettings, onDismiss: launchDeferredServerOnboardingIfNeeded) {
                SettingsView { server in
                    deferredServerOnboardingLaunch.request(prefill: server)
                    showSettings = false
                }
                    .environment(\.dependencies, dependencies)
            }
            .alert(
                "Could not start chat",
                isPresented: Binding(
                    get: { sessionHandoffError != nil },
                    set: { if !$0 { sessionHandoffError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sessionHandoffError ?? "")
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .startAgentSessionHandoff)
            ) { notification in
                guard let request = notification.object as? AgentSessionHandoffRequest else {
                    return
                }
                showSettings = false
                handleAgentSessionHandoff(request)
            }
            .onAppear {
                // Initialize coordinator on first appear
                if coordinator == nil {
                    coordinator = ContentViewCoordinator(
                        dependencies: dependencies
                    )
                }

                // Restore last active session
                if let activeId = eventStoreManager.activeSessionId,
                   eventStoreManager.sessionExists(activeId) {
                    presentSession(activeId)
                }
                // Refresh session list via the central coordinator — it coalesces duplicates
                // across call sites and handles the disconnected/connected/reconnecting cases
                // without blocking the view.
                eventStoreManager.requestSessionRefresh(reason: .foreground)

                // Cold launch share: the .pendingShareContent notification may have
                // fired before this view existed (app was still initializing). Check
                // for unconsumed share data and process it now.
                if PendingShareService.load() != nil {
                    handlePendingShare()
                }

                processPendingDeepLinkSession()
            }
            .onDisappear {}
            .onReceive(NotificationCenter.default.publisher(for: .serverSettingsDidChange)) { _ in
                eventStoreManager.requestSessionRefresh(reason: .settingsChanged)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSettingsAction)) { _ in
                showSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToSession)) { notification in
                if let sessionId = notification.object as? String {
                    coordinator?.handleDeepLink(
                        sessionId: sessionId,
                        scrollTarget: .bottom
                    ) { sessionId, scrollTarget in
                        presentSession(sessionId, scrollTarget: scrollTarget)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pendingShareContent)) { _ in
                handlePendingShare()
            }
            .onChange(of: selectedSessionId) { _, newValue in
                guard let newValue else { return }
                eventStoreManager.setActiveSession(newValue)
            }
            .onChange(of: compactSessionRoute) { oldValue, newValue in
                guard oldValue != nil, newValue == nil else { return }
                selectedSessionId = nil
                currentScrollTarget = nil
            }
            .onChange(of: deepLinkSessionId) { _, _ in
                processPendingDeepLinkSession()
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch primaryPage {
        case .sessions:
            splitViewContent
        case .engine:
            EngineDashboardPage(
                primaryPage: $primaryPage,
                viewModel: workerConsole,
                repository: dependencies.workerKernelRepository,
                actions: sessionListActions
            )
        case .activity:
            WorkerActivityPage(
                primaryPage: $primaryPage,
                viewModel: workerConsole,
                repository: dependencies.workerKernelRepository,
                actions: sessionListActions
            )
        }
    }

    private var sessionListActions: ShellToolbarActions {
        ShellToolbarActions(
            onSettings: { showSettings = true }
        )
    }

    /// Whether the sidebar is currently visible (for hiding duplicate controls in detail view)
    private var isSidebarVisible: Bool {
        // On regular size class, sidebar is visible when columnVisibility is .all or .doubleColumn
        horizontalSizeClass == .regular && (columnVisibility == .all || columnVisibility == .doubleColumn)
    }

    /// Toggle sidebar visibility
    private func toggleSidebar() {
        if columnVisibility == .detailOnly {
            columnVisibility = .all
        } else {
            columnVisibility = .detailOnly
        }
    }

    @ViewBuilder
    private var splitViewContent: some View {
        if horizontalSizeClass == .compact {
            // Use NavigationStack + navigationDestination on compact to ensure
            // .navigationBarBackButtonHidden(true) is applied before the push
            // animation starts. NavigationSplitView's compact push applies the
            // modifier too late, causing the default back button to flash.
            NavigationStack {
                sidebarContent
                    .navigationDestination(item: $compactSessionRoute) { route in
                        chatViewForSession(route.sessionId)
                            .id(route.presentationId)
                    }
            }
            .tint(.tronEmerald)
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarContent
            } detail: {
                detailContent
            }
            .navigationSplitViewStyle(.balanced)
            .scrollContentBackground(.hidden)
            .tint(.tronEmerald)
            .animation(.easeInOut(duration: 0.35), value: columnVisibility)
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        SessionSidebar(
            selectedSessionId: sidebarSessionSelection,
            primaryPage: $primaryPage,
            onNewSession: { showNewSessionSheet = true },
            onDeleteSession: { sessionId in
                deleteSession(sessionId)
            },
            actions: sessionListActions
        )
        // Remove default gray sidebar toggle - we'll add a custom emerald one to detail views
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let sessionId = selectedSessionId,
           shouldPresentSelectedSession(
               selectedSessionId: sessionId,
               knownSessionIds: Set(eventStoreManager.sessions.map(\.id))
           ) {
            chatViewForSession(sessionId)
        } else if eventStoreManager.sessions.isEmpty {
            WelcomePage(
                isSidebarVisible: isSidebarVisible,
                onToggleSidebar: toggleSidebar,
                onNewSession: { showNewSessionSheet = true },
                actions: sessionListActions
            )
        } else {
            selectSessionPrompt
        }
    }

    // MARK: - Sheet Content

    private var newSessionFlowSheet: some View {
        NewSessionFlow(
            connectionRepository: dependencies.connectionRepository,
            modelRepository: dependencies.modelRepository,
            sessionRepository: dependencies.sessionRepository,
            workspaceBrowserRepository: dependencies.workspaceBrowserRepository,
            defaultModel: defaultModel,
            defaultWorkspace: dependencies.quickSessionWorkspace,
            eventStoreManager: eventStoreManager,
            onSessionCreated: { created in
                guard let coordinator else {
                    throw ContentViewCoordinator.SessionPublicationError.coordinatorUnavailable
                }
                let sessionId = try await coordinator.publishCreatedSession(created)
                presentSession(sessionId)
                showNewSessionSheet = false
            }
        )
    }

    // MARK: - Event Handlers

    private var selectSessionPrompt: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                // Floating button hidden when the sidebar is visible to avoid duplicates.
                if !isSidebarVisible {
                    HStack(spacing: 12) {
                        FloatingNewSessionButton(action: { showNewSessionSheet = true })
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                }
            }
            .geometryGroup()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: toggleSidebar) {
                        Image(systemName: "sidebar.leading")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Tron")
                        .font(TronTypography.sans(size: 20, weight: .bold))
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
    }

    /// Creates a ChatView for the given session
    /// iPad (regular) gets sidebar toggle, iPhone (compact) uses back button
    /// Note: .id(sessionId) forces SwiftUI to treat each session as a unique view,
    /// destroying the old view and creating a fresh one when switching sessions.
    /// This ensures ChatViewModel is recreated with the correct sessionId.
    @ViewBuilder
    private func chatViewForSession(_ sessionId: String) -> some View {
        if horizontalSizeClass == .regular {
            ChatView(
                services: dependencies.chatSessionServices,
                sessionId: sessionId,
                scrollTarget: $currentScrollTarget,
                onToggleSidebar: toggleSidebar
            )
            .id(ChatSessionPresentationIdentity(
                sessionId: sessionId,
                serverSelectionVersion: dependencies.activeServerSelectionVersion
            ))
        } else {
            ChatView(
                services: dependencies.chatSessionServices,
                sessionId: sessionId,
                scrollTarget: $currentScrollTarget
            )
            .id(ChatSessionPresentationIdentity(
                sessionId: sessionId,
                serverSelectionVersion: dependencies.activeServerSelectionVersion
            ))
        }
    }

    private func deleteSession(_ sessionId: String) {
        coordinator?.deleteSession(sessionId, isSelected: selectedSessionId == sessionId) { nextId in
            presentSession(nextId)
        }
    }

    private func createQuickSession() {
        coordinator?.createQuickSession(selectedSessionId: selectedSessionId) { newId in
            presentSession(newId)
        }
    }

    private func handleAgentSessionHandoff(
        _ request: AgentSessionHandoffRequest
    ) {
        guard !isCreatingAgentSessionHandoff else { return }
        isCreatingAgentSessionHandoff = true
        let activeCoordinator: ContentViewCoordinator
        if let coordinator {
            activeCoordinator = coordinator
        } else {
            let created = ContentViewCoordinator(dependencies: dependencies)
            coordinator = created
            activeCoordinator = created
        }
        Task {
            defer { isCreatingAgentSessionHandoff = false }
            do {
                let sessionId = try await activeCoordinator.createSession(
                    for: request,
                    selectedSessionId: selectedSessionId
                )
                presentSession(sessionId)
            } catch {
                TronLogger.shared.error(
                    "Failed to create agent session handoff: \(error.localizedDescription)",
                    category: .session
                )
                sessionHandoffError = error.localizedDescription
            }
        }
    }

    private func handlePendingShare() {
        guard let shared = PendingShareService.load() else { return }
        PendingShareService.clear()

        guard let payload = shared.buildSharePrompt() else { return }

        coordinator?.createQuickSession(selectedSessionId: selectedSessionId) { newId in
            presentSession(newId)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                NotificationCenter.default.post(
                    name: .pendingShareMessage,
                    object: payload
                )
            }
        }
    }

    private func processPendingDeepLinkSession() {
        guard let pending = pendingSessionDeepLink(
            sessionId: deepLinkSessionId,
            scrollTarget: deepLinkScrollTarget
        ) else { return }

        coordinator?.handleDeepLink(
            sessionId: pending.sessionId,
            scrollTarget: pending.scrollTarget
        ) { sessionId, scrollTarget in
            presentSession(sessionId, scrollTarget: scrollTarget)
        }
        deepLinkSessionId = nil
        deepLinkScrollTarget = nil
    }

    private func launchDeferredServerOnboardingIfNeeded() {
        guard let request = deferredServerOnboardingLaunch.consume() else { return }
        ServerOnboardingLauncher.post(prefill: request.prefill)
    }

    private var sidebarSessionSelection: Binding<String?> {
        Binding(
            get: { selectedSessionId },
            set: { presentSession($0) }
        )
    }

    /// Opens a durable session selection through a fresh compact presentation.
    /// A repeated tap on the same session must rebuild `ChatView` and restart its
    /// reconstruction task after the previous presentation was popped.
    private func presentSession(
        _ sessionId: String?,
        scrollTarget: ScrollTarget? = nil
    ) {
        primaryPage = .sessions
        selectedSessionId = sessionId
        currentScrollTarget = scrollTarget
        if horizontalSizeClass == .compact {
            compactSessionRoute = makeCompactSessionRoute(sessionId: sessionId)
        }
    }
}

// MARK: - Quick Session Workspace Resolution

/// Resolves which workspace to use for a quick session.
///
/// Priority: explicit setting > current session > most recent session > default workspace.
/// The setting is considered "explicit" when non-empty and different from the default workspace.
func resolveQuickSessionWorkspace(
    setting: String,
    defaultWorkspace: String,
    selectedSessionId: String?,
    sessions: [CachedSession],
    sortedSessions: [CachedSession]
) -> String {
    // Setting takes priority — that's the whole point of the setting
    if !setting.isEmpty, setting != defaultWorkspace {
        return setting
    }
    // Fall back to current session
    if let currentId = selectedSessionId,
       let current = sessions.first(where: { $0.id == currentId }),
       !current.workingDirectory.isEmpty {
        return current.workingDirectory
    }
    // Fall back to most recent session
    if let mostRecent = sortedSessions.first,
       !mostRecent.workingDirectory.isEmpty {
        return mostRecent.workingDirectory
    }
    return defaultWorkspace
}

// MARK: - Welcome Page

struct WelcomePage: View {
    /// When true, sidebar is visible so we hide the duplicate floating button.
    var isSidebarVisible: Bool = false
    /// Toggle sidebar visibility (used on iPad)
    var onToggleSidebar: (() -> Void)?
    let onNewSession: () -> Void
    let actions: ShellToolbarActions

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                // Floating button hidden when the sidebar is visible to avoid duplicates.
                if !isSidebarVisible {
                    HStack(spacing: 12) {
                        FloatingNewSessionButton(action: onNewSession)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                }
            }
            .geometryGroup() // Ensures geometry changes animate together with NavigationSplitView
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ShellToolbarContent(
                    title: "Tron",
                    accent: .tronEmerald,
                    actions: actions,
                    onToggleSidebar: onToggleSidebar
                )
            }
        }
    }
}
