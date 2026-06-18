import SwiftUI

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.interactionPolicy) var interactionPolicy
    @Binding var selectedSessionId: String?
    @State private var sessionToArchive: String?
    @State private var showArchiveConfirmation = false
    @State private var workspaceExpansion = SessionDashboardWorkspaceExpansion()

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let actions: ShellToolbarActions

    private var workspaceGroups: [SessionDashboardWorkspaceGroup] {
        SessionDashboardWorkspaceGroup.groups(from: eventStoreManager.sortedSessions)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List(selection: $selectedSessionId) {
                ForEach(workspaceGroups) { group in
                    Section {
                        if workspaceExpansion.isExpanded(group.id) {
                            ForEach(group.sessions) { session in
                                sessionRow(session)
                            }
                        }
                    } header: {
                        SessionWorkspaceHeader(
                            title: group.name,
                            isExpanded: workspaceExpansion.isExpanded(group.id)
                        ) {
                            withAnimation(SessionDashboardLayout.expansionAnimation) {
                                workspaceExpansion.toggle(group.id)
                            }
                        }
                    }
                }
            }
            .tint(.clear)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, SessionDashboardLayout.minimumRowHeight)
            .contentMargins(.top, SessionDashboardLayout.listTopContentMargin)
            .contentMargins(.bottom, SessionDashboardLayout.listBottomContentMargin)

            let canCreate = interactionPolicy?.canCreateSession ?? false
            FloatingNewSessionButton(action: onNewSession, size: SessionDashboardLayout.floatingButtonSize)
                .disabled(!canCreate)
                .opacity(canCreate ? 1.0 : 0.4)
                .padding(.trailing, SessionDashboardLayout.floatingButtonTrailingPadding)
                .padding(.bottom, SessionDashboardLayout.floatingButtonBottomPadding)
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
    }

    @ViewBuilder
    private func sessionRow(_ session: CachedSession) -> some View {
        let isSelected = session.id == selectedSessionId
        let shape = RoundedRectangle(
            cornerRadius: SessionDashboardLayout.rowContainerCornerRadius,
            style: .continuous
        )

        Button {
            selectedSessionId = session.id
        } label: {
            SessionDashboardRow(session: session, isSelected: isSelected)
                .glassEffect(
                    .regular.tint(Color.tronEmerald.opacity(isSelected ? 0.22 : 0.14)).interactive(),
                    in: shape
                )
        }
        .buttonStyle(.plain)
        .tag(session.id)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionDashboardLayout.rowInsets)
        .opacity(session.isDeleting ? SessionDashboardLayout.deletingRowOpacity : 1.0)
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
