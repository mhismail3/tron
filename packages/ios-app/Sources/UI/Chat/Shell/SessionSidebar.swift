import SwiftUI

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.interactionPolicy) var interactionPolicy
    @Binding var selectedSessionId: String?
    @State private var sessionToArchive: String?
    @State private var showArchiveConfirmation = false
    @State private var workspaceDisclosure = SessionListWorkspaceDisclosure()
    @State private var sessionExpansion = SessionListSessionExpansion()

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    @Binding var primaryPage: TronPrimaryPage
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let actions: ShellToolbarActions

    private var workspaceGroups: [SessionListWorkspaceGroup] {
        SessionListWorkspaceGroup.groups(from: eventStoreManager.sortedSessions)
    }

    private var workspaceGroupCounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0.sessions.count) })
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List(selection: $selectedSessionId) {
                ForEach(workspaceGroups) { group in
                    let visibleSessions = sessionExpansion.visibleSessions(in: group)
                    let canViewMore = sessionExpansion.canViewMore(
                        groupId: group.id,
                        totalCount: group.sessions.count
                    )
                    let canViewLess = sessionExpansion.canViewLess(
                        groupId: group.id,
                        totalCount: group.sessions.count
                    )
                    let hasExpansionControls = canViewMore || canViewLess
                    let disclosureItemCount = visibleSessions.count + (hasExpansionControls ? 1 : 0)
                    let rowsAreVisible = workspaceDisclosure.areRowsVisible(group.id)
                    let paginationTransition = sessionExpansion.transition(for: group.id)
                    let paginationIsTransitioning = sessionExpansion.isTransitioning(groupId: group.id)

                    Section {
                        if workspaceDisclosure.shouldRenderRows(group.id) {
                            ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { index, session in
                                let paginationRowIsVisible = sessionExpansion.isRowVisible(
                                    groupId: group.id,
                                    index: index
                                )
                                sessionRow(session)
                                    .opacity(paginationRowIsVisible ? 1 : 0)
                                    .animation(
                                        paginationRowAnimation(
                                            transition: paginationTransition,
                                            index: index,
                                            isVisible: paginationRowIsVisible
                                        ),
                                        value: paginationRowIsVisible
                                    )
                                    .opacity(rowsAreVisible ? 1 : 0)
                                    .animation(
                                        SessionListLayout.disclosureRowAnimation(
                                            index: index,
                                            itemCount: disclosureItemCount,
                                            isVisible: rowsAreVisible
                                        ),
                                        value: rowsAreVisible
                                    )
                            }

                            if hasExpansionControls {
                                SessionListExpansionControls(
                                    projectName: group.name,
                                    canViewLess: canViewLess,
                                    canViewMore: canViewMore,
                                    isEnabled: !paginationIsTransitioning,
                                    onViewLess: {
                                        beginPaginationHide(group)
                                    },
                                    onViewMore: {
                                        beginPaginationReveal(group)
                                    }
                                )
                                .opacity(rowsAreVisible ? 1 : 0)
                                .animation(
                                    SessionListLayout.disclosureRowAnimation(
                                        index: visibleSessions.count,
                                        itemCount: disclosureItemCount,
                                        isVisible: rowsAreVisible
                                    ),
                                    value: rowsAreVisible
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(SessionListLayout.rowInsets)
                            }
                        }
                    } header: {
                        SessionWorkspaceHeader(
                            title: group.name,
                            isExpanded: workspaceDisclosure.isExpanded(group.id)
                        ) {
                            toggleWorkspaceGroup(group.id, itemCount: disclosureItemCount)
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
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ShellToolbarContent(
                title: "Tron",
                accent: .tronEmerald,
                actions: actions,
                primaryPage: $primaryPage
            )
        }
        .onChange(of: workspaceGroupCounts, initial: true) { _, groupCounts in
            sessionExpansion.reconcile(groupCounts: groupCounts)
            reconcileWorkspaceDisclosure(groupIds: Set(groupCounts.keys))
        }
    }

    private func toggleWorkspaceGroup(_ groupId: String, itemCount: Int) {
        let direction = workspaceDisclosure.toggleDirection(for: groupId)
        let transition: SessionListWorkspaceDisclosureTransition
        switch direction {
        case .collapse:
            transition = workspaceDisclosure.beginToggle(groupId)
        case .expand:
            transition = withAnimation(SessionListLayout.expansionAnimation) {
                workspaceDisclosure.beginToggle(groupId)
            }
        }

        Task { @MainActor in
            let delay = transition.direction == .collapse
                ? SessionListLayout.disclosureCollapseDelay(itemCount: itemCount)
                : SessionListLayout.disclosureLayoutDelay
            try? await Task.sleep(for: delay)
            if transition.direction == .collapse {
                _ = withAnimation(SessionListLayout.expansionAnimation) {
                    workspaceDisclosure.complete(transition)
                }
            } else {
                workspaceDisclosure.complete(transition)
            }
        }
    }

    private func reconcileWorkspaceDisclosure(groupIds: Set<String>) {
        workspaceDisclosure.reconcile(groupIds: groupIds)
    }

    private func paginationRowAnimation(
        transition: SessionListPaginationTransition?,
        index: Int,
        isVisible: Bool
    ) -> Animation? {
        guard let transition, index >= transition.stableCount else { return nil }
        return SessionListLayout.disclosureRowAnimation(
            index: index - transition.stableCount,
            itemCount: transition.affectedCount,
            isVisible: isVisible
        )
    }

    private func beginPaginationReveal(_ group: SessionListWorkspaceGroup) {
        guard let transition = withAnimation(SessionListLayout.expansionAnimation, {
            sessionExpansion.beginRevealMore(groupId: group.id, totalCount: group.sessions.count)
        }) else { return }

        Task { @MainActor in
            try? await Task.sleep(for: SessionListLayout.disclosureLayoutDelay)
            guard sessionExpansion.beginRevealRows(transition) else { return }
            try? await Task.sleep(
                for: SessionListLayout.disclosureCollapseDelay(itemCount: transition.affectedCount)
            )
            sessionExpansion.finish(transition)
        }
    }

    private func beginPaginationHide(_ group: SessionListWorkspaceGroup) {
        guard let transition = sessionExpansion.beginShowLess(
            groupId: group.id,
            totalCount: group.sessions.count
        ) else { return }

        Task { @MainActor in
            try? await Task.sleep(
                for: SessionListLayout.disclosureCollapseDelay(itemCount: transition.affectedCount)
            )
            _ = withAnimation(SessionListLayout.expansionAnimation) {
                sessionExpansion.finish(transition)
            }
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
