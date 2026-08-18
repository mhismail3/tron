import SwiftUI

struct SessionShellProfileRouteOwner {
    private var hasObservedProfile = false
    private var profileID: String?

    mutating func reconcile(
        profileID nextProfileID: String?,
        presentedSession: inout AppModel.SessionNavigationRoute?,
        presentationTarget: (String) -> AppModel.SessionPresentationTarget?,
        revoke: (AppModel.SessionPresentationTarget) -> Void
    ) {
        guard hasObservedProfile else {
            hasObservedProfile = true
            profileID = nextProfileID
            return
        }
        guard profileID != nextProfileID else { return }
        profileID = nextProfileID
        if let sessionID = presentedSession?.sessionID,
           let target = presentationTarget(sessionID) {
            revoke(target)
        }
        presentedSession = nil
    }
}

struct SessionShellView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewSession = false
    @State private var newSessionDetent: PresentationDetent = .medium
    @State private var showSettings = false
    @State private var search = ""
    @State private var showingSearch = false
    @State private var presentedSession: AppModel.SessionNavigationRoute?
    @State private var sessionToDelete: SessionSummary?
    @State private var sessionToRename: SessionSummary?
    @State private var renameName = ""
    @State private var workspaceDisclosure = SessionListWorkspaceDisclosure()
    @State private var sessionExpansion = SessionListSessionExpansion()
    @State private var navigationOwner = DashboardNavigationOwner()
    @State private var profileRouteOwner = SessionShellProfileRouteOwner()

    var body: some View {
        dashboardNavigation
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(onCreated: present)
                .tronTopBlur(.sheet)
                .presentationDetents([.medium, .large], selection: $newSessionDetent)
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onImported: { route in
                showSettings = false
                present(route)
            })
            .presentationDragIndicator(.hidden)
        }
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
        .onChange(of: model.profiles.selected?.id, initial: true) { _, profileID in
            var route = presentedSession
            profileRouteOwner.reconcile(
                profileID: profileID,
                presentedSession: &route,
                presentationTarget: model.presentationTarget(for:),
                revoke: model.revokePresentationIntake
            )
            if presentedSession != route {
                navigationOwner.invalidate()
                presentedSession = route
            }
        }
        .onChange(of: model.visibleSessions, initial: true) { _, sessions in
            let groups = SessionListWorkspaceGroup.groups(from: sessions)
            sessionExpansion.reconcile(
                groupCounts: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.sessions.count) })
            )
            workspaceDisclosure.reconcile(groupIDs: Set(groups.map(\.id)))
        }
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
                    initialModel: route.initialModel,
                    onForkCreated: present
                )
                .id(route.sessionID)
            }
    }

    private func present(_ route: AppModel.SessionNavigationRoute) {
        navigationOwner.invalidate()
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
            Image("TronLogoVector")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 28)
                .foregroundStyle(Color.tronEmerald)
                .accessibilityLabel("Tron")
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
        ForEach(workspaceGroups) { group in
            let visibleSessions = sessionExpansion.visibleSessions(in: group)
            let canShowMore = sessionExpansion.canViewMore(
                groupID: group.id,
                totalCount: group.sessions.count
            )
            let canShowLess = sessionExpansion.canViewLess(
                groupID: group.id,
                totalCount: group.sessions.count
            )
            let hasExpansionControls = canShowMore || canShowLess
            let disclosureItemCount = visibleSessions.count + (hasExpansionControls ? 1 : 0)
            let rowsAreVisible = workspaceDisclosure.areRowsVisible(group.id)
            let paginationTransition = sessionExpansion.transition(for: group.id)
            let paginationIsTransitioning = sessionExpansion.isTransitioning(groupID: group.id)

            Section {
                if workspaceDisclosure.shouldRenderRows(group.id) {
                    ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { index, session in
                        let paginationRowIsVisible = sessionExpansion.isRowVisible(
                            groupID: group.id,
                            index: index
                        )
                        sessionButton(session)
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
                                SessionDashboardLayout.disclosureRowAnimation(
                                    index: index,
                                    itemCount: disclosureItemCount,
                                    isVisible: rowsAreVisible
                                ),
                                value: rowsAreVisible
                            )
                    }

                    if hasExpansionControls {
                        SessionListExpansionControls(
                            workspaceName: group.name,
                            canShowLess: canShowLess,
                            canShowMore: canShowMore,
                            isEnabled: !paginationIsTransitioning,
                            onShowLess: { beginPaginationHide(group) },
                            onShowMore: { beginPaginationReveal(group) }
                        )
                        .opacity(rowsAreVisible ? 1 : 0)
                        .animation(
                            SessionDashboardLayout.disclosureRowAnimation(
                                index: visibleSessions.count,
                                itemCount: disclosureItemCount,
                                isVisible: rowsAreVisible
                            ),
                            value: rowsAreVisible
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(SessionDashboardLayout.rowInsets)
                    }
                }
            } header: {
                workspaceHeader(group, itemCount: disclosureItemCount)
            }
        }
    }

    private func sessionButton(_ session: SessionSummary) -> some View {
        return Button {
            present(AppModel.SessionNavigationRoute(sessionID: session.id, editorText: nil))
        } label: {
            HistoricalSessionRow(
                session: session,
                activity: model.dashboardActivity(for: session.id)
            )
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

    private func workspaceHeader(
        _ group: SessionListWorkspaceGroup,
        itemCount: Int
    ) -> some View {
        let isExpanded = workspaceDisclosure.isExpanded(group.id)
        return Button {
            toggleWorkspaceGroup(group.id, itemCount: itemCount)
        } label: {
            HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: SessionDashboardLayout.headerIconSize, weight: .semibold))
                    .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)
                    .contentTransition(.symbolEffect(.replace))
                Text(group.name)
                    .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(Color.tronEmerald)
            .padding(.leading, SessionDashboardLayout.headerLeadingPadding)
            .padding(.trailing, SessionDashboardLayout.rowContainerHorizontalInset)
            .padding(.top, SessionDashboardLayout.headerTopPadding)
            .padding(.bottom, SessionDashboardLayout.headerBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(SessionDashboardLayout.expansionAnimation, value: isExpanded)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .listRowInsets(SessionDashboardLayout.headerInsets)
        .accessibilityLabel(group.name)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint(isExpanded ? "Double tap to hide sessions" : "Double tap to show sessions")
    }

    private var workspaceGroups: [SessionListWorkspaceGroup] {
        let filtered = model.visibleSessions.filter { session in
            search.isEmpty
                || session.title.localizedCaseInsensitiveContains(search)
                || session.cwd.localizedCaseInsensitiveContains(search)
        }
        return SessionListWorkspaceGroup.groups(from: filtered)
            .map { group in
                SessionListWorkspaceGroup(
                    path: group.path,
                    name: group.name,
                    sessions: group.sessions.sorted { $0.updatedAt > $1.updatedAt }
                )
            }
            .sorted {
                $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
    }

    private func toggleWorkspaceGroup(_ groupID: String, itemCount: Int) {
        let direction = workspaceDisclosure.toggleDirection(for: groupID)
        let transition: SessionListWorkspaceDisclosureTransition
        switch direction {
        case .collapse:
            transition = workspaceDisclosure.beginToggle(groupID)
        case .expand:
            transition = withAnimation(SessionDashboardLayout.expansionAnimation) {
                workspaceDisclosure.beginToggle(groupID)
            }
        }

        Task { @MainActor in
            let delay = transition.direction == .collapse
                ? SessionDashboardLayout.disclosureCollapseDelay(itemCount: itemCount)
                : SessionDashboardLayout.disclosureLayoutDelay
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if transition.direction == .collapse {
                _ = withAnimation(SessionDashboardLayout.expansionAnimation) {
                    workspaceDisclosure.complete(transition)
                }
            } else {
                workspaceDisclosure.complete(transition)
            }
        }
    }

    private func paginationRowAnimation(
        transition: SessionListPaginationTransition?,
        index: Int,
        isVisible: Bool
    ) -> Animation? {
        guard let transition, index >= transition.stableCount else { return nil }
        return SessionDashboardLayout.disclosureRowAnimation(
            index: index - transition.stableCount,
            itemCount: transition.affectedCount,
            isVisible: isVisible
        )
    }

    private func beginPaginationReveal(_ group: SessionListWorkspaceGroup) {
        guard let transition = withAnimation(SessionDashboardLayout.expansionAnimation, {
            sessionExpansion.beginRevealMore(
                groupID: group.id,
                totalCount: group.sessions.count
            )
        }) else { return }

        Task { @MainActor in
            try? await Task.sleep(for: SessionDashboardLayout.disclosureLayoutDelay)
            guard !Task.isCancelled,
                  sessionExpansion.beginRevealRows(transition) else { return }
            try? await Task.sleep(
                for: SessionDashboardLayout.disclosureCollapseDelay(itemCount: transition.affectedCount)
            )
            guard !Task.isCancelled else { return }
            sessionExpansion.finish(transition)
        }
    }

    private func beginPaginationHide(_ group: SessionListWorkspaceGroup) {
        guard let transition = sessionExpansion.beginShowLess(
            groupID: group.id,
            totalCount: group.sessions.count
        ) else { return }

        Task { @MainActor in
            try? await Task.sleep(
                for: SessionDashboardLayout.disclosureCollapseDelay(itemCount: transition.affectedCount)
            )
            guard !Task.isCancelled else { return }
            _ = withAnimation(SessionDashboardLayout.expansionAnimation) {
                sessionExpansion.finish(transition)
            }
        }
    }
}

private enum SessionDashboardLayout {
    static let rowContainerHorizontalInset: CGFloat = 16
    static let rowContentHorizontalPadding: CGFloat = 12
    static let iconColumnWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 8
    static let minimumRowHeight: CGFloat = 38
    static let headerIconSize: CGFloat = 14
    static let headerChevronSize: CGFloat = 10
    static let headerTopPadding: CGFloat = 10
    static let headerBottomPadding: CGFloat = 3
    static let expansionControlMinimumHeight: CGFloat = 44
    static let expansionControlTitleSize: CGFloat = 13
    static let expansionAnimation = Animation.smooth(duration: 0.18)
    static let disclosureRowFadeDuration: TimeInterval = 0.13
    static let disclosureMaximumStaggerDuration: TimeInterval = 0.06
    static let disclosureLayoutDelay: Duration = .milliseconds(180)
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

    static var expansionControlLeadingPadding: CGFloat { rowContentHorizontalPadding }
    static var expansionControlTrailingPadding: CGFloat { rowContentHorizontalPadding }

    static func disclosureRowDelay(
        index: Int,
        itemCount: Int,
        isVisible: Bool
    ) -> TimeInterval {
        let boundedCount = max(itemCount, 1)
        let boundedIndex = min(max(index, 0), boundedCount - 1)
        let order = isVisible ? boundedIndex : boundedCount - boundedIndex - 1
        let step = boundedCount > 1
            ? disclosureMaximumStaggerDuration / Double(boundedCount - 1)
            : 0
        return Double(order) * step
    }

    static func disclosureRowAnimation(
        index: Int,
        itemCount: Int,
        isVisible: Bool
    ) -> Animation {
        .easeOut(duration: disclosureRowFadeDuration)
            .delay(disclosureRowDelay(index: index, itemCount: itemCount, isVisible: isVisible))
    }

    static func disclosureCollapseDelay(itemCount: Int) -> Duration {
        let stagger = itemCount > 1 ? disclosureMaximumStaggerDuration : 0
        let milliseconds = Int(((disclosureRowFadeDuration + stagger) * 1_000).rounded(.up))
        return .milliseconds(milliseconds)
    }
}

private struct SessionListExpansionControls: View {
    let workspaceName: String
    let canShowLess: Bool
    let canShowMore: Bool
    let isEnabled: Bool
    let onShowLess: () -> Void
    let onShowMore: () -> Void

    var body: some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            if canShowMore {
                expansionButton(
                    title: "Show more",
                    symbolName: "chevron.down",
                    hint: "Shows 10 more older sessions in \(workspaceName)",
                    action: onShowMore
                )
                .transition(.opacity)
            }

            Spacer(minLength: SessionDashboardLayout.iconTextSpacing)

            if canShowLess {
                expansionButton(
                    title: "Show less",
                    symbolName: "chevron.up",
                    hint: "Shows only the latest 10 sessions in \(workspaceName)",
                    action: onShowLess
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, SessionDashboardLayout.expansionControlLeadingPadding)
        .padding(.trailing, SessionDashboardLayout.expansionControlTrailingPadding)
        .disabled(!isEnabled)
    }

    private func expansionButton(
        title: String,
        symbolName: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
                Text(title)
                    .font(
                        TronTypography.sans(
                            size: SessionDashboardLayout.expansionControlTitleSize,
                            weight: .semibold
                        )
                    )
                Image(systemName: symbolName)
                    .font(.system(size: SessionDashboardLayout.headerChevronSize, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.tronEmerald)
            .frame(minHeight: SessionDashboardLayout.expansionControlMinimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("\(title) sessions in \(workspaceName)")
        .accessibilityHint(hint)
    }
}

private struct HistoricalSessionRow: View {
    let session: SessionSummary
    let activity: DashboardSessionActivity

    var body: some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            Group {
                if activity == .active || activity == .resuming {
                    ProgressView().controlSize(.small).tint(.tronEmerald)
                } else {
                    Image(systemName: activity == .interrupted ? "exclamationmark.circle" : "circle")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(activity == .interrupted ? Color.tronAmber : Color.tronEmerald.opacity(0.82))
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
        .accessibilityLabel("\(session.title), \(activity.accessibilityDescription), \(session.relativeActivityDescription())")
    }
}

private extension DashboardSessionActivity {
    var accessibilityDescription: String {
        switch self {
        case .idle: "idle"
        case .active: "active"
        case .resuming: "resuming"
        case .interrupted: "interrupted"
        }
    }
}
