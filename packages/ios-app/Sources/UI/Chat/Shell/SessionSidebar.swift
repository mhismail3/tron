import SwiftUI

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.interactionPolicy) var interactionPolicy
    @Binding var selectedSessionId: String?
    @State private var sessionToArchive: String?
    @State private var showArchiveConfirmation = false
    @State private var workspaceExpansion = SessionListWorkspaceExpansion()
    @State private var sessionExpansion = SessionListSessionExpansion()
    @State private var agentBriefing = AgentBriefingViewModel()
    @State private var engineCockpit = AgentCockpitViewModel()
    @State private var showAgentBriefing = false
    @State private var showEngineCockpit = false

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let actions: ShellToolbarActions

    private var workspaceGroups: [SessionListWorkspaceGroup] {
        SessionListWorkspaceGroup.groups(from: eventStoreManager.sortedSessions)
    }

    private var workspaceGroupCounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0.sessions.count) })
    }

    private var briefingSessionId: String? {
        selectedSessionId ?? eventStoreManager.sortedSessions.first?.id
    }

    private var briefingRefreshKey: AgentBriefingDashboardRefreshKey {
        AgentBriefingDashboardRefreshKey(
            sessionId: briefingSessionId,
            isConnected: dependencies.connectionRepository.connectionState.isConnected
        )
    }

    private var cockpitRefreshKey: EngineCockpitDashboardRefreshKey {
        EngineCockpitDashboardRefreshKey(
            sessionId: briefingSessionId,
            isConnected: dependencies.connectionRepository.connectionState.isConnected
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List(selection: $selectedSessionId) {
                Section {
                    AgentBriefingDashboardBand(
                        state: agentBriefing.state,
                        isRefreshing: agentBriefing.isRefreshing
                    ) {
                        showAgentBriefing = true
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(SessionListLayout.briefingInsets)
                }

                Section {
                    EngineCockpitDashboardBand(
                        overview: engineCockpit.overview,
                        isRefreshing: engineCockpit.isRefreshing
                    ) {
                        showEngineCockpit = true
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(SessionListLayout.briefingInsets)
                }

                ForEach(workspaceGroups) { group in
                    Section {
                        if workspaceExpansion.isExpanded(group.id) {
                            ForEach(sessionExpansion.visibleSessions(in: group)) { session in
                                sessionRow(session)
                            }

                            let canViewMore = sessionExpansion.canViewMore(
                                groupId: group.id,
                                totalCount: group.sessions.count
                            )
                            let canViewLess = sessionExpansion.canViewLess(
                                groupId: group.id,
                                totalCount: group.sessions.count
                            )
                            if canViewMore || canViewLess {
                                SessionListExpansionControls(
                                    projectName: group.name,
                                    canViewLess: canViewLess,
                                    canViewMore: canViewMore,
                                    onViewLess: {
                                        withAnimation(SessionListLayout.expansionAnimation) {
                                            sessionExpansion.showLess(groupId: group.id)
                                        }
                                    },
                                    onViewMore: {
                                        withAnimation(SessionListLayout.expansionAnimation) {
                                            sessionExpansion.revealMore(
                                                groupId: group.id,
                                                totalCount: group.sessions.count
                                            )
                                        }
                                    }
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(SessionListLayout.rowInsets)
                            }
                        }
                    } header: {
                        SessionWorkspaceHeader(
                            title: group.name,
                            isExpanded: workspaceExpansion.isExpanded(group.id)
                        ) {
                            withAnimation(SessionListLayout.expansionAnimation) {
                                workspaceExpansion.toggle(group.id)
                            }
                        }
                    }
                }
            }
            .tint(.clear)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, SessionListLayout.minimumRowHeight)
            .contentMargins(.top, SessionListLayout.listTopContentMargin)
            .contentMargins(.bottom, SessionListLayout.listBottomContentMargin)

            let canCreate = interactionPolicy?.canCreateSession ?? false
            FloatingNewSessionButton(action: onNewSession, size: SessionListLayout.floatingButtonSize)
                .disabled(!canCreate)
                .opacity(canCreate ? 1.0 : 0.4)
                .padding(.trailing, SessionListLayout.floatingButtonTrailingPadding)
                .padding(.bottom, SessionListLayout.floatingButtonBottomPadding)
        }
        .background {
            Color.clear
                .alert("Archive Session", isPresented: $showArchiveConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Archive", role: .destructive) {
                        if let id = sessionToArchive {
                            onDeleteSession(id)
                        }
                    }
                } message: {
                    Text("This will archive the session from your device. Server data will remain.")
                }
                .tint(.gray)
        }
        .tronScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbar(removing: .sidebarToggle)
        .toolbar {
            ShellToolbarContent(title: "Tron", accent: .tronEmerald, actions: actions)
        }
        .onChange(of: workspaceGroupCounts, initial: true) { _, groupCounts in
            sessionExpansion.reconcile(groupCounts: groupCounts)
        }
        .task(id: briefingRefreshKey) {
            await refreshBriefing()
        }
        .task(id: cockpitRefreshKey) {
            await refreshCockpit()
        }
        .sheet(isPresented: $showAgentBriefing) {
            AgentBriefingSheet(
                viewModel: agentBriefing,
                repository: dependencies.workerLifecycleRepository,
                sessionId: briefingSessionId,
                workspaceId: nil,
                connectionState: dependencies.connectionRepository.connectionState
            )
        }
        .sheet(isPresented: $showEngineCockpit) {
            AgentCockpitSheet(
                viewModel: engineCockpit,
                repository: dependencies.workerLifecycleRepository,
                sessionId: briefingSessionId,
                workspaceId: nil,
                connectionState: dependencies.connectionRepository.connectionState
            )
        }
    }

    private func refreshBriefing() async {
        await agentBriefing.refresh(
            repository: dependencies.workerLifecycleRepository,
            sessionId: briefingSessionId,
            workspaceId: nil,
            connectionState: dependencies.connectionRepository.connectionState
        )
    }

    private func refreshCockpit() async {
        await engineCockpit.refresh(
            repository: dependencies.workerLifecycleRepository,
            sessionId: briefingSessionId,
            workspaceId: nil,
            connectionState: dependencies.connectionRepository.connectionState
        )
    }

    @ViewBuilder
    private func sessionRow(_ session: CachedSession) -> some View {
        let isSelected = session.id == selectedSessionId
        let shape = RoundedRectangle(
            cornerRadius: SessionListLayout.rowContainerCornerRadius,
            style: .continuous
        )

        Button {
            selectedSessionId = session.id
        } label: {
            SessionListRow(session: session, isSelected: isSelected)
                .contentShape(shape)
                .glassEffect(
                    .regular.tint(Color.tronEmerald.opacity(isSelected ? 0.22 : 0.14)).interactive(),
                    in: shape
                )
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .tag(session.id)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionListLayout.rowInsets)
        .opacity(session.isDeleting ? SessionListLayout.deletingRowOpacity : 1.0)
        .allowsHitTesting(!session.isDeleting)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            archiveSwipeAction(for: session)
        }
    }

    @ViewBuilder
    private func archiveSwipeAction(for session: CachedSession) -> some View {
        if !session.isDeleting && (interactionPolicy?.canMutateSession ?? false) {
            Button {
                sessionToArchive = session.id
                showArchiveConfirmation = true
            } label: {
                Image(systemName: "archivebox")
            }
            .tint(.tronEmerald)
        }
    }
}

private struct AgentBriefingDashboardRefreshKey: Equatable {
    let sessionId: String?
    let isConnected: Bool
}

private struct EngineCockpitDashboardRefreshKey: Equatable {
    let sessionId: String?
    let isConnected: Bool
}
