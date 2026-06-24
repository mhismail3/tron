import SwiftUI

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.interactionPolicy) var interactionPolicy
    @Binding var selectedSessionId: String?
    @State private var sessionToArchive: String?
    @State private var showArchiveConfirmation = false
    @State private var workspaceExpansion = SessionListWorkspaceExpansion()

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let actions: ShellToolbarActions

    private var workspaceGroups: [SessionListWorkspaceGroup] {
        SessionListWorkspaceGroup.groups(from: eventStoreManager.sortedSessions)
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
                .glassEffect(
                    .regular.tint(Color.tronEmerald.opacity(isSelected ? 0.22 : 0.14)).interactive(),
                    in: shape
                )
        }
        .buttonStyle(.plain)
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
