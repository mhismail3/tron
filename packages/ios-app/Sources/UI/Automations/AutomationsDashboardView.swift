import SwiftUI

struct AutomationSummarySelection: Hashable, Identifiable {
    let profileID: String
    let summary: GatewayAutomationSummary
    var highlightedOccurrence: String? = nil
    var id: String { "\(profileID):\(summary.id)" }
}

enum AutomationTimelinePresentationPolicy {
    static let agendaVerticalPadding: CGFloat = 12
    static let bottomControlClearance: CGFloat = 80
    static let minimumEmptyStateHeight: CGFloat = 280
    static let initialLoadingPulseSize: CGFloat = 44

    static func showsInitialLoading(
        mode: AutomationDashboardViewMode,
        catalogHasLoaded: Bool,
        timelineAvailable: Bool,
        timelineIsLoading: Bool,
        visibleDayCount: Int
    ) -> Bool {
        guard catalogHasLoaded else { return true }
        guard mode == .upcoming else { return false }
        return !timelineAvailable || (timelineIsLoading && visibleDayCount == 0)
    }

    static func showsEmptyState(visibleDayCount: Int) -> Bool {
        visibleDayCount == 0
    }

    static func emptyStateHeight(viewportHeight: CGFloat, hasAttentionBanner: Bool) -> CGFloat {
        guard !hasAttentionBanner else { return minimumEmptyStateHeight }
        return max(
            minimumEmptyStateHeight,
            viewportHeight - (agendaVerticalPadding * 2) - bottomControlClearance
        )
    }

    static func showsRefreshIndicator(isLoading: Bool, delayElapsed: Bool) -> Bool {
        isLoading && delayElapsed
    }

    static func showsInventoryFilters(mode: AutomationDashboardViewMode) -> Bool {
        mode == .all
    }
}

struct AutomationsDashboardView: View {
    let onSelectDashboard: @MainActor (DashboardMode) -> Void
    let onOpenSettings: @MainActor () -> Void
    let onOpenSession: @MainActor (String, String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var viewPreferences: AutomationDashboardViewPreferences
    @State private var search = ""
    @State private var showingSearch = false
    @State private var dashboardHeader = DashboardHeaderState()
    @State private var showingFilters = false
    @State private var selected: AutomationSummarySelection?
    @State private var createPresented = false
    @State private var selectedDate = Date.now
    @State private var datePickerPresented = false
    @State private var timeline: AutomationTimelineCoordinator?
    @State private var timelineRefreshIndicatorVisible = false

    init(
        viewPreferences: Binding<AutomationDashboardViewPreferences>,
        onSelectDashboard: @escaping @MainActor (DashboardMode) -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onOpenSession: @escaping @MainActor (String, String) -> Void
    ) {
        _viewPreferences = viewPreferences
        self.onSelectDashboard = onSelectDashboard
        self.onOpenSettings = onOpenSettings
        self.onOpenSession = onOpenSession
    }

    private var eligibleProfileIDs: Set<String> {
        Set(model.automationCatalog.allEndpoints().map(\.id))
    }

    private var availableBuckets: [AutomationProfileCatalog] {
        model.automationCatalog.buckets.filter { eligibleProfileIDs.contains($0.id) }
    }

    private var allowsTimelineWork: Bool {
        presentationActivity.allowsPresentationPublication && scenePhase == .active && mode == .upcoming
    }

    private var mode: AutomationDashboardViewMode { viewPreferences.mode }
    private var filter: AutomationInventoryFilter { viewPreferences.inventoryFilter }
    private var actionFilter: AutomationActionKind? { viewPreferences.actionFilter }
    private var serverFilter: String? {
        viewPreferences.effectiveProfileID(eligibleProfileIDs: eligibleProfileIDs)
    }

    private var summaries: [(profile: AutomationDashboardProfile, summary: GatewayAutomationSummary)] {
        model.automationCatalog.summaries.filter { profile, summary in
            eligibleProfileIDs.contains(profile.id)
                && (serverFilter == nil || serverFilter == profile.id)
                && filter.matches(summary)
                && (actionFilter == nil || summary.typedActionKind == actionFilter)
                && (search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || summary.name.localizedCaseInsensitiveContains(search))
        }.sorted { left, right in
            let attention = (left.summary.isAttentionRequired ? 0 : 1, right.summary.isAttentionRequired ? 0 : 1)
            if attention.0 != attention.1 { return attention.0 < attention.1 }
            let running = (left.summary.currentRun?.state == .running ? 0 : 1, right.summary.currentRun?.state == .running ? 0 : 1)
            if running.0 != running.1 { return running.0 < running.1 }
            return (left.summary.nextOccurrenceAt ?? "9999", left.summary.name) < (right.summary.nextOccurrenceAt ?? "9999", right.summary.name)
        }
    }

    private var summarySelections: [AutomationSummarySelection] {
        summaries.map { AutomationSummarySelection(profileID: $0.profile.id, summary: $0.summary) }
    }

    private var isInitiallyLoading: Bool {
        AutomationTimelinePresentationPolicy.showsInitialLoading(
            mode: mode,
            catalogHasLoaded: model.automationCatalog.hasLoaded,
            timelineAvailable: timeline != nil,
            timelineIsLoading: timeline?.isLoading == true,
            visibleDayCount: visibleTimelineDays.count
        )
    }

    private var visibleTimelineDays: [AutomationAgendaDay] {
        (timeline?.days ?? []).compactMap { day in
            let items = day.items.filter {
                eligibleProfileIDs.contains($0.profileID)
                    && (serverFilter == nil || $0.profileID == serverFilter)
            }
            return items.isEmpty ? nil : AutomationAgendaDay(date: day.date, items: items)
        }
    }

    private var attentionCount: Int {
        model.automationCatalog.summaries.count {
            eligibleProfileIDs.contains($0.profile.id)
                && (serverFilter == nil || $0.profile.id == serverFilter)
                && $0.summary.isAttentionRequired
        }
    }

    var body: some View {
        DashboardChrome(
            mode: .automations,
            header: dashboardHeader,
            onSelect: onSelectDashboard,
            actions: dashboardMenuActions,
            showingSearch: showingSearch,
            isRefreshing: mode == .upcoming && timelineRefreshIndicatorVisible && !isInitiallyLoading
        ) {
            content
        } search: {
            automationSearchBar
        }
        .tronPresentation()
        .tronSettingsVisualTheme(accent: .tronAutomation)
        .task(id: PresentationActivityTaskID(
            source: scenePhase,
            presentationActive: presentationActivity.allowsDataPublication
        )) {
            // Descendant detail/form screens consume the narrow catalog's
            // revisions. Timeline derivation is dashboard-only work below.
            if presentationActivity.allowsDataPublication, scenePhase == .active {
                if presentationActivity.allowsPresentationPublication { reconcileViewPreferences() }
                model.automationCatalog.activate()
            } else {
                model.automationCatalog.deactivate()
            }
        }
        .onChange(of: allowsTimelineWork, initial: true) { _, active in
            if active {
                reconcileViewPreferences()
                if timeline == nil {
                    timeline = AutomationTimelineCoordinator(endpoints: { @MainActor in
                        model.automationCatalog.allEndpoints()
                    })
                }
            }
            timeline?.setPresentationActive(active)
            if active, mode == .upcoming { timeline?.load(start: selectedDate) }
        }
        .task(id: timeline?.isLoading == true) {
            guard timeline?.isLoading == true else {
                timelineRefreshIndicatorVisible = false
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled, allowsTimelineWork,
                  AutomationTimelinePresentationPolicy.showsRefreshIndicator(
                    isLoading: timeline?.isLoading == true,
                    delayElapsed: true
                  ) else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                timelineRefreshIndicatorVisible = true
            }
        }
        .onChange(of: model.automationCatalog.timelineAdmissionKey) { _, _ in
            // A catalog publication refreshes the timeline only when its
            // endpoint, connection, capability, or authoritative revision
            // changes. Failure text and retained stale rows are not timeline
            // inputs and must not restart an in-flight read.
            if mode == .upcoming { timeline?.load(start: selectedDate) }
        }
        .onChange(of: mode) { _, nextMode in
            dashboardHeader.update(offset: 0)
            if nextMode == .upcoming {
                dismissAutomationSearch()
                timeline?.load(start: selectedDate)
            }
        }
        .onChange(of: model.profileRevision) { _, _ in
            if presentationActivity.allowsPresentationPublication { reconcileViewPreferences() }
            model.automationCatalog.invalidate()
        }
        .onChange(of: model.connectionState) { _, _ in
            model.automationCatalog.invalidate()
        }
        .onDisappear {
            model.automationCatalog.deactivate()
            timeline?.cancel()
            timeline = nil
            timelineRefreshIndicatorVisible = false
        }
        .tronManagedSheet(item: $selected, identity: { "automation.detail.\($0.id)" }) { selection in
            AutomationDetailView(selection: selection, onOpenSession: onOpenSession)
        }
        .tronManagedSheet(isPresented: $createPresented, identity: "automation.create") {
            AutomationFormView(selection: nil, onSaved: { createPresented = false })
        }
        .tronManagedSheet(isPresented: $showingFilters, identity: "automation.filters") {
            automationFilterSheet
        }
        .tronManagedSheet(isPresented: $datePickerPresented, identity: "automation.date-picker") {
            NavigationStack {
                DatePicker("Start date", selection: $selectedDate, in: Date.now..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .tronNavigationTitle("Jump to date", accent: .tronAutomation)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { datePickerPresented = false; timeline?.load(start: selectedDate) } label: { Image(systemName: "checkmark") }
                                .accessibilityLabel("Done")
                        }
                    }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
            .tronSettingsVisualTheme(accent: .tronAutomation)
        }
    }

    private var content: some View {
        ZStack {
            if isInitiallyLoading {
                TronPulseLoadingIndicator(
                    accent: .tronAutomation,
                    size: AutomationTimelinePresentationPolicy.initialLoadingPulseSize
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading Automations")
                .tronDashboardInitialOffset()
                .transition(TronDashboardContentMotion.transition(reduceMotion: reduceMotion))
            } else if mode == .all {
                inventoryList
                    .transition(TronDashboardContentMotion.transition(reduceMotion: reduceMotion))
            } else {
                upcomingContent
                    .transition(TronDashboardContentMotion.transition(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            TronDashboardContentMotion.animation(reduceMotion: reduceMotion),
            value: isInitiallyLoading
        )
    }

    private var inventoryList: some View {
        ScrollView {
            LazyVStack(spacing: TronSpacing.md) {
                if summaries.isEmpty {
                    inventoryEmptyState
                        .transition(.opacity)
                } else {
                    ForEach(summarySelections) { item in
                        if let profile = model.automationCatalog.buckets.first(where: { $0.profile.id == item.profileID })?.profile {
                            automationCard(profile, item.summary)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .animation(
                TronDashboardContentMotion.animation(reduceMotion: reduceMotion),
                value: summarySelections
            )
            .padding(.horizontal, 20).padding(.vertical, 16).padding(.bottom, 80)
        }
        .tronScrollEdgeChrome()
        .tronDashboardScroll(dashboardHeader)
    }

    private var upcomingContent: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.md, pinnedViews: [.sectionHeaders]) {
                    if attentionCount > 0 {
                        attentionBanner.transition(.opacity)
                    }
                    if AutomationTimelinePresentationPolicy.showsEmptyState(
                        visibleDayCount: visibleTimelineDays.count
                    ) {
                        upcomingEmptyState
                            .frame(minHeight: AutomationTimelinePresentationPolicy.emptyStateHeight(
                                viewportHeight: geometry.size.height,
                                hasAttentionBanner: attentionCount > 0
                            ))
                            .transition(.opacity)
                    } else {
                        ForEach(visibleTimelineDays) { day in
                            Section {
                                ForEach(day.items) { item in occurrenceRow(item) }
                            } header: {
                                dayHeader(
                                    day.date,
                                    count: day.items.reduce(0) { $0 + ($1.occurrence.count ?? 1) }
                                )
                            }
                            .onAppear {
                                if day.id == visibleTimelineDays.last?.id { timeline?.loadNext() }
                            }
                            .transition(.opacity)
                        }
                        if timeline?.isLoadingMore == true {
                            TronLoadingState(label: "Loading later dates…", accent: .tronAutomation)
                                .frame(minHeight: 80)
                        } else if timeline?.canLoadMore == false {
                            Text("Choose another date to continue beyond this bounded agenda window.")
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextMuted)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .animation(
                    TronDashboardContentMotion.animation(reduceMotion: reduceMotion),
                    value: visibleTimelineDays
                )
                .animation(
                    TronDashboardContentMotion.animation(reduceMotion: reduceMotion),
                    value: attentionCount
                )
                .padding(.horizontal, 20)
                .padding(.vertical, AutomationTimelinePresentationPolicy.agendaVerticalPadding)
                .padding(.bottom, AutomationTimelinePresentationPolicy.bottomControlClearance)
            }
            .tronScrollEdgeChrome()
            .tronDashboardScroll(dashboardHeader)
        }
    }

    private func occurrenceTime(_ value: String) -> String {
        guard let date = GatewayTimestamp.parse(value) else { return "—" }
        let formatter = DateFormatter(); formatter.timeStyle = .short; return formatter.string(from: date)
    }

    private func dayHeader(_ date: Date, count: Int) -> some View {
        let calendar = Calendar.current
        let title = calendar.isDateInToday(date) ? "Today" : calendar.isDateInTomorrow(date) ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return HStack { Text(title).font(TronTypography.sheetSectionHeader).foregroundStyle(Color.tronAutomation); Spacer(); Text("\(count) trigger\(count == 1 ? "" : "s")").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted) }
            .padding(.vertical, 6).background(Color.tronBackground.opacity(0.96))
    }

    private func occurrenceRow(_ item: AutomationTimelineItem) -> some View {
        let occurrence = item.occurrence
        // Resolve once for the row's labels; the tap below re-resolves against
        // current authoritative data so it cannot act on a replaced summary.
        let match = model.automationCatalog.summaries.first {
            $0.profile.id == item.profileID && $0.summary.id == occurrence.automationId
        }
        return Button {
            if let summary = model.automationCatalog.summaries.first(where: { $0.profile.id == item.profileID && $0.summary.id == occurrence.automationId }) {
                selected = AutomationSummarySelection(
                    profileID: summary.profile.id,
                    summary: summary.summary,
                    highlightedOccurrence: occurrence.presentationTimestamp
                )
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(occurrenceTime(occurrence.presentationTimestamp)).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronAutomation).frame(width: 64, alignment: .leading)
                Image(systemName: occurrence.isSeries ? "repeat" : "circle.fill").foregroundStyle(Color.tronAutomation).padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    if let match {
                        Text(match.summary.name).font(TronTypography.body).foregroundStyle(Color.tronTextPrimary).lineLimit(1)
                        Text("\(match.summary.typedActionKind?.label ?? "Action") · \(targetLabel(profileID: item.profileID, target: match.summary.target))").font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary).lineLimit(2)
                        Text(match.profile.label + (match.summary.trigger.kind == "calendar" ? " · \(match.summary.trigger.timezone ?? "")" : "")).font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted).lineLimit(2)
                    } else { Text("Automation \(occurrence.automationId)").foregroundStyle(Color.tronTextSecondary) }
                    if occurrence.isSeries { Text("\(occurrence.count ?? 0) triggers · \(AutomationDateFormatting.date(occurrence.firstAt))–\(AutomationDateFormatting.date(occurrence.lastAt))").font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted) }
                }
                Spacer(minLength: 0)
            }
            .padding(TronSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("automation-occurrence-card.\(occurrence.automationId)")
        .tronGlassSurface(accent: .tronAutomation, cornerRadius: 14, tintOpacity: 0.08, interactive: true)
        .accessibilityLabel("Scheduled automation")
    }

    private func automationCard(_ profile: AutomationDashboardProfile, _ summary: GatewayAutomationSummary) -> some View {
        let status = summary.currentRun?.state.label ?? summary.activation.label
        let timing = summary.lastRun.map { "Last \(AutomationDateFormatting.relative($0.terminalAt ?? $0.scheduledFor))" }
            ?? summary.nextOccurrenceAt.map { "Next \(AutomationDateFormatting.relative($0))" }
            ?? "No run yet"
        return Button { selected = AutomationSummarySelection(profileID: profile.id, summary: summary) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: summary.typedActionKind?.icon ?? "clock")
                    .foregroundStyle(Color.tronAutomation)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([status, summary.trigger.summary, timing].joined(separator: " · "))
                        .font(TronTypography.bodySM)
                        .foregroundStyle(summary.isAttentionRequired ? Color.tronError : Color.tronTextSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = summary.blockedReason {
                        Text(reason)
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronError)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TronSpacing.lg)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("automation-card.\(summary.id)")
        .tronGlassSurface(
            accent: summary.isAttentionRequired ? .tronError : .tronAutomation,
            cornerRadius: 12,
            tintOpacity: 0.14,
            interactive: true
        )
        .accessibilityLabel(AutomationStatusPresentation.accessible(summary))
    }

    private var attentionBanner: some View {
        Button {
            dismissAutomationSearch()
            updateViewPreferences {
                $0.actionFilter = nil
                $0.inventoryFilter = .attention
                $0.mode = .all
            }
        } label: {
            TronInfoCard(
                icon: "exclamationmark.triangle.fill",
                text: "\(attentionCount) Automation\(attentionCount == 1 ? "" : "s") need\(attentionCount == 1 ? "s" : "") attention.",
                accent: .tronError,
                usesSemanticAccent: true
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows Automations that need attention")
    }

    private var inventoryEmptyState: some View {
        let filtered = filter != .all || actionFilter != nil || serverFilter != nil || !search.isEmpty
        return emptyState(
            icon: filtered ? "line.3.horizontal.decrease.circle" : "clock.badge.checkmark",
            title: filtered ? "No matches" : "No Automations",
            message: filtered
                ? "Adjust the current view or filters to show more Automations."
                : "Create a durable prompt or notification schedule for a persisted session."
        )
    }

    private var upcomingEmptyState: some View {
        emptyState(
            icon: "calendar",
            title: "Nothing upcoming",
            message: "Enabled Automations on connected, compatible Gateways will appear here."
        )
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        TronPlaceholderState(title: title, detail: message, icon: icon, accent: .tronAutomation)
            .frame(minHeight: 280)
    }

    private func targetLabel(profileID: String, target: GatewayAutomationTarget) -> String {
        switch target {
        case let .existingSession(sessionID):
            return model.visibleSessions.first(where: {
                $0.id == sessionID && ($0.gatewayProfileID == profileID || ($0.gatewayProfileID == nil && profileID == model.profiles.selected?.id))
            })?.title ?? "Session \(sessionID)"
        case let .workspace(cwd, _):
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return "New session per run · \(name.isEmpty ? "Workspace" : name)"
        }
    }

    private var dashboardMenuActions: DashboardMenuActions {
        DashboardMenuActions(
            search: showAutomationSearch,
            filter: { showingFilters = true },
            settings: onOpenSettings,
            additionalControls: mode == .upcoming
                ? [.init(title: "Choose agenda date", symbol: "calendar", perform: { datePickerPresented = true })]
                : [],
            creation: [.init(title: "Create Automation", symbol: "plus", perform: { createPresented = true })]
        )
    }

    private var automationSearchBar: some View {
        TronSearchBar(
            text: $search,
            prompt: "Search Automations",
            accent: .tronAutomation,
            focusOnAppear: true,
            onClose: dismissAutomationSearch,
            onFocusChange: { focused in
                if !focused { dismissAutomationSearch() }
            }
        )
        .padding(.horizontal, TronSpacing.section)
        .padding(.vertical, 8)
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    guard value.translation.height > 28,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    dismissAutomationSearch()
                }
        )
    }

    private func showAutomationSearch() {
        // Search targets the inventory, never the chronological agenda. Admit
        // that explicit view choice through the existing preference owner.
        updateViewPreferences { $0.mode = .all }
        withAnimation(.snappy(duration: 0.18)) { showingSearch = true }
    }

    private func dismissAutomationSearch() {
        guard showingSearch || !search.isEmpty else { return }
        withAnimation(.snappy(duration: 0.18)) {
            search = ""
            showingSearch = false
        }
    }

    private func updateViewPreferences(
        _ update: (inout AutomationDashboardViewPreferences) -> Void
    ) {
        var next = viewPreferences
        update(&next)
        guard next != viewPreferences else { return }
        viewPreferences = next
    }

    private func reconcileViewPreferences() {
        var next = viewPreferences
        next.reconcile(knownProfileIDs: model.profiles.profiles.compactMap { profile in
            guard profile.isEnabled, model.profiles.token(for: profile) != nil else { return nil }
            return profile.id
        })
        guard next != viewPreferences else { return }
        viewPreferences = next
    }

    private var automationFilterSheet: some View {
        TronDashboardFilterSheet(
            title: "View Automations",
            accent: .tronAutomation,
            detents: [.medium],
            onDone: { showingFilters = false }
        ) {
            TronDashboardFilterSectionTitle(
                title: "View",
                detail: "Choose the dashboard projection to display."
            )
            ForEach(AutomationDashboardViewMode.allCases) { option in
                TronDashboardFilterOption(
                    title: option.rawValue,
                    detail: option == .upcoming
                        ? "Chronological schedule from connected Gateways."
                        : "Search and manage every available Automation.",
                    selected: mode == option,
                    accent: .tronAutomation,
                    inactiveAccent: .tronSlate
                ) {
                    updateViewPreferences { $0.mode = option }
                }
            }

            if AutomationTimelinePresentationPolicy.showsInventoryFilters(mode: mode) {
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    TronDashboardFilterSectionTitle(
                        title: "Status",
                        detail: "Limit the inventory by lifecycle state."
                    )
                    .padding(.top, TronSpacing.md)
                    ForEach(AutomationInventoryFilter.allCases) { option in
                        TronDashboardFilterOption(
                            title: option.rawValue,
                            selected: filter == option,
                            accent: .tronAutomation,
                            inactiveAccent: .tronSlate
                        ) {
                            updateViewPreferences { $0.inventoryFilter = option }
                        }
                    }

                    TronDashboardFilterSectionTitle(
                        title: "Action",
                        detail: "Show prompts, notifications, or both."
                    )
                    .padding(.top, TronSpacing.md)
                    TronDashboardFilterOption(
                        title: "All action types",
                        selected: actionFilter == nil,
                        accent: .tronAutomation,
                        inactiveAccent: .tronSlate
                    ) {
                        updateViewPreferences { $0.actionFilter = nil }
                    }
                    ForEach(AutomationActionKind.allCases, id: \.self) { action in
                        TronDashboardFilterOption(
                            title: action.label,
                            selected: actionFilter == action,
                            accent: .tronAutomation,
                            inactiveAccent: .tronSlate
                        ) {
                            updateViewPreferences { $0.actionFilter = action }
                        }
                    }
                }
                .transition(.opacity)
            }

            if availableBuckets.count > 1 {
                TronDashboardFilterSectionTitle(
                    title: "Gateway",
                    detail: "Show Automations from one connected Gateway or all of them."
                )
                .padding(.top, TronSpacing.md)
                TronDashboardFilterOption(
                    title: "All Gateways",
                    selected: serverFilter == nil,
                    accent: .tronAutomation,
                    inactiveAccent: .tronSlate
                ) {
                    updateViewPreferences { $0.selectedProfileID = nil }
                }
                ForEach(availableBuckets) { bucket in
                    TronDashboardFilterOption(
                        title: bucket.profile.label,
                        detail: "Connected",
                        selected: serverFilter == bucket.profile.id,
                        accent: .tronAutomation,
                        inactiveAccent: .tronSlate
                    ) {
                        updateViewPreferences { $0.selectedProfileID = bucket.profile.id }
                    }
                }
            }
        }
    }

}
