import SwiftUI

enum PushNavigationFailureAdmission {
    static func admits(requestID: Int, pendingRequestID: Int?) -> Bool {
        !Task.isCancelled && pendingRequestID == requestID
    }
}

enum PushNavigationPresentationPolicy {
    static func retainsCurrent(presentedRouteID: String?, targetRouteID: String) -> Bool {
        presentedRouteID == targetRouteID
    }
}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dashboardMode: DashboardMode = .sessions
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
    @State private var routeReplacementOwner = SessionRouteReplacementOwner()
    @State private var mountedSessionRouteToken: PresentationSurfaceToken?
    @State private var profileRouteOwner = SessionShellProfileRouteOwner()
    @State private var serverFilter = DashboardServerFilterState()
    @State private var showingServerFilter = false
    @State private var openingSessionID: String?
    @State private var dashboardPresentation = DashboardPresentationSnapshot()
    @State private var dashboardPresentationIsActive = false
    @State private var dashboardReconcileTask: Task<Void, Never>?

    init() {
        _serverFilter = State(initialValue: DashboardServerFilterPreferences.load())
    }

    var body: some View {
        TronPresentationSurface(id: "dashboard") {
            TronPresentationActivityReader { activity in
                dashboardSurface(activity: activity)
            }
        }
    }

    private func dashboardSurface(activity: PresentationSurfaceActivity) -> some View {
        dashboardNavigation
            .tronManagedSheet(
                isPresented: $showNewSession,
                identity: "dashboard.new-session"
            ) {
                NewSessionSheet(onCreated: present)
                    .tronTopBlur(.sheet)
                    .presentationDetents([.medium, .large], selection: $newSessionDetent)
                    .presentationDragIndicator(.hidden)
            }
            .tronManagedSheet(
                isPresented: $showSettings,
                identity: "dashboard.settings"
            ) {
                SettingsView(onImported: { route in
                    showSettings = false
                    present(route)
                })
                .presentationDragIndicator(.hidden)
            }
            .tronManagedSheet(
                isPresented: $showingServerFilter,
                identity: "dashboard.server-filter"
            ) {
                serverFilterSheet
                    .tronTopBlur(.sheet)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.hidden)
            }
            .tronManagedSheet(
                item: $sessionToDelete,
                identity: { "dashboard.delete.\($0.id)" }
            ) { session in
                TronConfirmationSheet(
                    title: "Delete \(session.title)?",
                    message: "This removes the canonical session from the Mac and cannot be undone.",
                    confirmTitle: "Delete",
                    destructive: true,
                    icon: "trash",
                    onConfirm: { delete(session) }
                )
            }
            .tronTextEntryAlert(
                "Rename Session",
                isPresented: renameConfirmationPresented,
                text: $renameName,
                placeholder: "Session name"
            ) { value in
                guard let session = sessionToRename else { return }
                rename(session, name: value)
            }
            .tronManagedSystemPresentation(
                isPresented: renameConfirmationPresented,
                identity: "dashboard.rename-confirmation"
            )
            .onChange(of: model.profiles.selected?.id, initial: true) { previousProfileID, profileID in
                if previousProfileID != profileID { routeReplacementOwner.invalidate() }
                var route = presentedSession
                profileRouteOwner.reconcile(
                    profileID: profileID,
                    presentedSession: &route,
                    presentationTarget: model.presentationTarget(for:),
                    revoke: model.revokePresentationIntake
                )
                if presentedSession != route {
                    navigationOwner.invalidate()
                    routeReplacementOwner.invalidate()
                    presentedSession = route
                }
                if activity.allowsPresentationPublication { scheduleDashboardReconciliation() }
            }
            .background {
                if activity.allowsPresentationPublication {
                    Color.clear
                        .onChange(of: model.dashboardPresentationRevision, initial: true) { _, _ in
                            scheduleDashboardReconciliation()
                        }
                }
            }
            .onChange(of: model.profileRevision) { _, _ in
                guard activity.allowsPresentationPublication else { return }
                scheduleDashboardReconciliation()
            }
            .onChange(of: activity, initial: true) { _, current in
                dashboardPresentationIsActive = current.allowsPresentationPublication
                if dashboardPresentationIsActive {
                    scheduleDashboardReconciliation()
                } else {
                    dashboardReconcileTask?.cancel()
                    dashboardReconcileTask = nil
                }
            }
            .onDisappear {
                dashboardReconcileTask?.cancel()
                dashboardReconcileTask = nil
            }
            .task(id: model.actionablePushNavigationRequest?.id) {
                guard let request = model.actionablePushNavigationRequest else { return }
                await presentPushNavigation(request)
            }
    }

    private var dashboardNavigation: some View {
        NavigationStack {
            dashboardScreen
        }
        .tint(Color.tronEmerald)
    }

    private var dashboardScreen: some View {
        Group {
            if dashboardMode == .automations {
                AutomationsDashboardView(
                    onSelectSessions: { dashboardMode = .sessions },
                    onOpenSettings: { showSettings = true }
                )
            } else {
                sessionDashboardScreen
            }
        }
    }

    private var sessionDashboardScreen: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .bottomTrailing) {
                sessionList
                TronTopBlurOverlay(style: .dashboard)
                dashboardBottomControls
                    .accessibilityHidden(showingSearch)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            if showingSearch {
                dashboardSearchBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.tronBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if dashboardMode == .sessions { dashboardToolbar }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(item: $presentedSession) { route in
            ChatView(
                sessionID: route.sessionID,
                initialEditorText: route.editorText,
                initialModel: route.initialModel,
                onForkCreated: present
            )
            .id(route.id)
            .tronPresentationSurface(
                id: "chat.\(route.id)",
                onMount: { token in
                    guard presentedSession?.id == route.id else { return }
                    mountedSessionRouteToken = token
                },
                onRetire: { token in
                    if mountedSessionRouteToken == token { mountedSessionRouteToken = nil }
                    completeRouteReplacement(afterRetiring: route.id, token: token)
                }
            )
        }
    }

    private var dashboardSearchBar: some View {
        TronSearchBar(
            text: $search,
            prompt: "Search sessions",
            focusOnAppear: true,
            onClose: dismissDashboardSearch,
            onFocusChange: { focused in
                if !focused { dismissDashboardSearch() }
            }
        )
        .padding(.horizontal, TronSpacing.section)
        .padding(.vertical, 8)
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    guard value.translation.height > 28,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    dismissDashboardSearch()
                }
        )
    }

    private func present(_ route: AppModel.SessionNavigationRoute) {
        guard model.ownsNavigationRoute(route) else { return }
        navigationOwner.invalidate()
        let current = presentedSession
        if let current,
           let target = model.presentationTarget(for: current.sessionID) {
            model.revokePresentationIntake(target)
        }
        switch routeReplacementOwner.request(
            current: current,
            currentToken: mountedSessionRouteToken,
            replacement: route
        ) {
        case .present(let admitted):
            presentedSession = admitted
        case .dismissCurrent:
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentedSession = nil }
        case .waitForRetirement:
            break
        }
    }

    private func completeRouteReplacement(
        afterRetiring routeID: String,
        token: PresentationSurfaceToken
    ) {
        guard let replacement = routeReplacementOwner.completeRetirement(
            routeID: routeID,
            token: token
        ) else { return }
        Task { @MainActor in
            await Task.yield()
            guard presentedSession == nil,
                  model.ownsNavigationRoute(replacement) else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentedSession = replacement }
        }
    }

    @MainActor
    private func presentPushNavigation(_ request: AppModel.PushNavigationRequest) async {
        navigationOwner.invalidate()
        routeReplacementOwner.invalidate()
        showNewSession = false
        showSettings = false
        showingServerFilter = false
        if showingSearch { dismissDashboardSearch() }

        do {
            // Keep the current chat mounted while the target transport is being
            // prepared. A slow reconnect must not strand the user on an empty
            // dashboard, and an exact same-route tap is a navigation no-op.
            let route = try await model.navigationRoute(for: request.tap)
            try Task.checkCancellation()
            guard model.pushNavigationRequest?.id == request.id,
                  model.ownsNavigationRoute(route) else { return }
            if PushNavigationPresentationPolicy.retainsCurrent(
                presentedRouteID: presentedSession?.id,
                targetRouteID: route.id
            ) {
                model.consumePushNavigation(request.id)
                return
            }

            if let current = presentedSession {
                if let target = model.presentationTarget(for: current.sessionID) {
                    model.revokePresentationIntake(target)
                }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                    presentedSession = nil
                }
                if !reduceMotion {
                    try await Task.sleep(for: .milliseconds(260))
                }
            }

            try Task.checkCancellation()
            guard model.pushNavigationRequest?.id == request.id,
                  model.ownsNavigationRoute(route) else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                present(route)
            }
            model.consumePushNavigation(request.id)
        } catch is CancellationError {
            return
        } catch {
            guard PushNavigationFailureAdmission.admits(
                requestID: request.id,
                pendingRequestID: model.pushNavigationRequest?.id
            ) else { return }
            model.consumePushNavigation(request.id)
            model.presentError(error)
        }
    }

    private var dashboardBottomControls: some View {
        HStack(alignment: .bottom) {
            dashboardSearchControl
            Spacer(minLength: 12)
            newSessionButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var dashboardSearchControl: some View {
        Button(action: showDashboardSearch) {
            Image(systemName: "magnifyingglass")
                .font(TronTypography.sans(size: 22, weight: .semibold))
        }
        .buttonStyle(TronIconButtonStyle(size: 56))
        .accessibilityLabel("Search sessions")
    }

    private func showDashboardSearch() {
        withAnimation(.snappy(duration: 0.18)) {
            showingSearch = true
        }
    }

    private func dismissDashboardSearch() {
        guard showingSearch || !search.isEmpty else { return }
        withAnimation(.snappy(duration: 0.18)) {
            search = ""
            showingSearch = false
        }
    }

    private var serverFilterSheet: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    Text("View")
                        .font(TronTypography.sheetSectionHeader)
                        .foregroundStyle(Color.tronTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(DashboardSessionSortMode.allCases) { mode in
                        filterOption(
                            title: mode.rawValue,
                            detail: mode.detail,
                            selected: serverFilter.sortMode == mode
                        ) {
                            setSortMode(mode)
                        }
                    }

                    VStack(alignment: .leading, spacing: TronSpacing.xs) {
                        Text("Servers")
                            .font(TronTypography.sheetSectionHeader)
                            .foregroundStyle(Color.tronTextPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Choose one or more servers to show in your session history.")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, TronSpacing.md)
                    filterOption(
                        title: "All servers",
                        detail: "Show sessions from every paired server.",
                        selected: serverFilter.isAllSelected
                    ) {
                        updateServerFilter { $0.selectAll() }
                    }

                    ForEach(model.dashboardServerSources) { source in
                        filterOption(
                            title: source.label,
                            detail: "\(source.sessionCount) session\(source.sessionCount == 1 ? "" : "s") · \(source.state.label)",
                            selected: serverFilter.isSelected(source.profileID)
                        ) {
                            updateServerFilter { $0.toggle(source.profileID) }
                        }
                    }
                }
                .padding(.horizontal, TronSpacing.xlarge)
                .padding(.vertical, TronSpacing.large)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Filter Servers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { showingServerFilter = false } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
    }

    private func setSortMode(_ mode: DashboardSessionSortMode) {
        updateServerFilter { $0.setSortMode(mode) }
    }

    private func updateServerFilter(_ update: (inout DashboardServerFilterState) -> Void) {
        update(&serverFilter)
        DashboardServerFilterPreferences.save(serverFilter)
    }

    private func filterOption(
        title: String,
        detail: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: TronSpacing.xl) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.tronEmerald : Color.tronTextMuted)
                    .frame(width: 20, height: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: TronSpacing.md)
            }
            .padding(.horizontal, TronSpacing.xl)
            .padding(.vertical, TronSpacing.md)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .tronGlassSurface(
            accent: selected ? .tronEmerald : .tronCyan,
            cornerRadius: 12,
            tintOpacity: selected ? 0.18 : 0.08,
            interactive: true
        )
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    }

    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            DashboardModeMenuButton(mode: dashboardMode) { selected in
                dashboardMode = selected
            }
            .frame(width: 34, height: 34)
            .accessibilityLabel("Switch dashboard")
            .accessibilityValue(dashboardMode.rawValue)
        }
        ToolbarItem(placement: .principal) {
            Text("Tron")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                .foregroundStyle(Color.tronEmerald)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showingServerFilter = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel(serverFilter.accessibilityLabel)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Settings")
        }
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

    private func rename(_ session: SessionSummary, name value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do { try await model.performOnOwningGateway(session) { try await model.renameSession(session.id, name: name) } }
            catch { model.presentError(error) }
            sessionToRename = nil
        }
    }

    private func delete(_ session: SessionSummary) {
        Task {
            do { try await model.performOnOwningGateway(session) { try await model.deleteSession(session.id) } }
            catch { model.presentError(error) }
            sessionToDelete = nil
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
        .transaction { transaction in
            // Keep the dashboard projection visually stable while a focused
            // server connection is being replaced. The bounded old buckets
            // remain visible until the new authoritative catalog arrives.
            if model.connectionState == .connecting || model.connectionState == .reconnecting {
                transaction.animation = nil
            }
        }
    }

    @ViewBuilder
    private var sessionSections: some View {
        if serverFilter.sortMode == .recent {
            Section {
                ForEach(recentSessions, id: \.dashboardID) { session in
                    sessionButton(session, showsContext: true)
                }
            } header: {
                recentActivityHeader
            }
        } else {
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
                    ForEach(Array(visibleSessions.enumerated()), id: \.element.dashboardID) { index, session in
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
    }

    private var recentActivityHeader: some View {
        Text("Recent Activity · active first")
            .font(TronTypography.sheetSectionHeader)
            .foregroundStyle(Color.tronEmerald)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SessionDashboardLayout.headerLeadingPadding)
            .padding(.top, SessionDashboardLayout.headerTopPadding)
            .padding(.bottom, SessionDashboardLayout.headerBottomPadding)
            .listRowInsets(SessionDashboardLayout.headerInsets)
    }

    private func sessionButton(_ session: SessionSummary, showsContext: Bool = false) -> some View {
        return Button {
            guard openingSessionID == nil else { return }
            openingSessionID = session.dashboardID
            let navigationIntent = navigationOwner.begin()
            Task {
                defer { openingSessionID = nil }
                do {
                    let route = try await model.navigationRoute(for: session)
                    guard navigationOwner.admit(navigationIntent),
                          model.ownsNavigationRoute(route) else { return }
                    present(route)
                } catch is CancellationError {
                    return
                } catch {
                    model.presentError(error)
                }
            }
        } label: {
            HistoricalSessionRow(
                session: session,
                activity: dashboardPresentation.activity(for: session),
                showsContext: showsContext
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-row-\(session.dashboardID)")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionDashboardLayout.rowInsets)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(
                session.isUnread ? "Mark Read" : "Mark Unread",
                systemImage: session.isUnread ? "circle" : "circle.fill"
            ) {
                Task {
                    do { try await model.setSessionUnread(session, unread: !session.isUnread) }
                    catch is CancellationError { return }
                    catch { model.presentError(error) }
                }
            }
            .tint(Color.gray)
            .accessibilityIdentifier("session-attention-action-\(session.dashboardID)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash") { sessionToDelete = session }
                .tint(Color.tronError)
                .accessibilityIdentifier("session-delete-action-\(session.dashboardID)")
            Button("Rename", systemImage: "pencil") { beginRename(session) }
                .tint(Color.tronEmerald)
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
                    .font(TronTypography.sans(size: SessionDashboardLayout.headerIconSize, weight: .semibold))
                    .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)
                    .contentTransition(.symbolEffect(.replace))
                Text(group.name)
                    .font(TronTypography.code(size: TronTypography.sizeBodyLG, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: SessionDashboardLayout.iconTextSpacing)
                if let serverName = group.profileLabel, !serverName.isEmpty {
                    Text(serverName)
                        .font(TronTypography.code(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: SessionDashboardLayout.headerChevronSize, weight: .bold))
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

    private func scheduleDashboardReconciliation() {
        guard dashboardPresentationIsActive, dashboardReconcileTask == nil else { return }
        dashboardReconcileTask = Task { @MainActor in
            defer { dashboardReconcileTask = nil }
            do { try await DisplayFrameScheduler.displayLink.nextFrame() }
            catch { return }
            guard !Task.isCancelled, dashboardPresentationIsActive else { return }
            reconcileDashboardPresentation()
        }
    }

    private func reconcileDashboardPresentation() {
        let sessions = model.visibleSessions
        dashboardPresentation = DashboardPresentationSnapshot(
            sessions: sessions,
            activityByDashboardID: Dictionary(uniqueKeysWithValues: sessions.map { session in
                (session.dashboardID, model.dashboardActivity(for: session))
            })
        )
        let groups = SessionListWorkspaceGroup.groups(from: sessions)
        sessionExpansion.reconcile(
            groupCounts: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.sessions.count) })
        )
        workspaceDisclosure.reconcile(groupIDs: Set(groups.map(\.id)))
        let sources = model.dashboardServerSources
        serverFilter.reconcile(profileIDs: sources.map(\.profileID))
        if !sources.isEmpty { DashboardServerFilterPreferences.save(serverFilter) }
    }

    private var filteredSessions: [SessionSummary] {
        dashboardPresentation.sessions.filter { session in
            serverFilter.allows(
                session.gatewayProfileID,
                selectedProfileID: model.profiles.selected?.id
            )
                && (search.isEmpty
                    || session.title.localizedCaseInsensitiveContains(search)
                    || session.cwd.localizedCaseInsensitiveContains(search))
        }
    }

    private var recentSessions: [SessionSummary] {
        filteredSessions
    }

    private var workspaceGroups: [SessionListWorkspaceGroup] {
        SessionListWorkspaceGroup.groups(from: filteredSessions)
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
                    .font(TronTypography.sans(size: SessionDashboardLayout.headerChevronSize, weight: .bold))
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

enum DashboardSessionIndicatorState: Hashable {
    case idleRead
    case idleUnread
    case active
    case waitingForUser
    case subagentsWorking
    case resuming
    case interrupted

    init(activity: DashboardSessionActivity, isUnread: Bool) {
        self = switch activity {
        case .idle: isUnread ? .idleUnread : .idleRead
        case .active: .active
        case .waitingForUser: .waitingForUser
        case .subagentsWorking: .subagentsWorking
        case .resuming: .resuming
        case .interrupted: .interrupted
        }
    }
}

@MainActor
enum DashboardSessionIndicatorPresentation {
    static let subagentOrbSize = TronTypography.sizeBody3
}

private struct HistoricalSessionRow: View {
    let session: SessionSummary
    let activity: DashboardSessionActivity
    let showsContext: Bool
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        Group {
            if PresentationClockPolicy.runs(
                surfaceActive: presentationActivity.allowsContinuousAnimation,
                sceneActive: scenePhase == .active,
                viewportVisible: isVisible
            ) {
                TimelineView(.periodic(from: .now, by: DashboardActivityClock.refreshInterval)) { timeline in
                    row(relativeTo: timeline.date)
                }
            } else {
                row(relativeTo: .now)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private func row(relativeTo now: Date) -> some View {
        let relativeActivity = session.relativeActivityDescription(relativeTo: now)
        let trailingStatus = activity == .waitingForUser ? "Waiting for you" : relativeActivity
        return HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            ZStack {
                sessionIndicator
                    .id(indicatorState)
                    .transition(indicatorTransition)
            }
            .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)
            .animation(indicatorAnimation, value: indicatorState)

            VStack(alignment: .leading, spacing: showsContext ? 2 : 0) {
                Text(session.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsContext {
                    Text(projectServerContext)
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(Color.tronTextMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 10)

            HStack(spacing: 5) {
                if session.isFork {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                        .accessibilityHidden(true)
                }
                Text(trailingStatus)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(activity == .waitingForUser ? Color.tronAmber : Color.tronTextMuted)
                    .lineLimit(1)
            }
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
        .accessibilityLabel("\(session.title)\(session.isFork ? ", forked session" : ""), \(activity.accessibilityDescription)\(session.isUnread ? ", unread" : ""), \(relativeActivity)")
    }

    private var indicatorState: DashboardSessionIndicatorState {
        DashboardSessionIndicatorState(activity: activity, isUnread: session.isUnread)
    }

    @ViewBuilder
    private var sessionIndicator: some View {
        switch indicatorState {
        case .subagentsWorking:
            ProcessActivityOrb(
                mode: .solving,
                size: DashboardSessionIndicatorPresentation.subagentOrbSize,
                isVisible: isVisible
            )
        case .active, .resuming:
            TronPulseLoadingIndicator(accent: .tronEmerald, size: 18)
        case .waitingForUser:
            Image(systemName: "questionmark.bubble.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(Color.tronAmber)
        case .interrupted:
            Image(systemName: "exclamationmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(Color.tronAmber)
        case .idleUnread:
            Image(systemName: "circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(Color.tronEmerald.opacity(0.82))
        case .idleRead:
            Image(systemName: "circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(Color.tronEmerald.opacity(0.82))
        }
    }

    private var indicatorTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.72).combined(with: .opacity),
            removal: .scale(scale: 1.14).combined(with: .opacity)
        )
    }

    private var indicatorAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.3, dampingFraction: 0.8)
    }

    private var projectServerContext: String {
        let project = URL(fileURLWithPath: session.cwd).lastPathComponent
        let projectName = project.isEmpty ? session.cwd : project
        let serverName = session.gatewayProfileLabel.flatMap { label in
            label.isEmpty ? nil : label
        } ?? "Unknown server"
        return "\(projectName) · \(serverName)"
    }
}

private extension DashboardSessionActivity {
    var accessibilityDescription: String {
        switch self {
        case .idle: "idle"
        case .active: "active"
        case .waitingForUser: "waiting for you"
        case .subagentsWorking: "subagents working"
        case .resuming: "resuming"
        case .interrupted: "interrupted"
        }
    }
}
