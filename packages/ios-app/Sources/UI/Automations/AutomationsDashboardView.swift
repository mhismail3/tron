import SwiftUI

struct AutomationSummarySelection: Hashable, Identifiable {
    let profileID: String
    let summary: GatewayAutomationSummary
    var highlightedOccurrence: String? = nil
    var id: String { "\(profileID):\(summary.id)" }
}

enum AutomationDashboardViewMode: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming", all = "All"
    var id: String { rawValue }
}

enum AutomationInventoryFilter: String, CaseIterable, Identifiable {
    case all = "All", active = "Active", attention = "Needs attention", drafts = "Drafts", paused = "Paused", completed = "Completed"
    var id: String { rawValue }
    func matches(_ summary: GatewayAutomationSummary) -> Bool {
        switch self {
        case .all: true
        case .active: summary.activation == .enabled
        case .attention: summary.isAttentionRequired
        case .drafts: summary.activation == .draft
        case .paused: summary.activation == .paused
        case .completed: summary.activation == .completed
        }
    }
}

enum AutomationTimelinePresentationPolicy {
    static func showsEmptyState(visibleDayCount: Int) -> Bool {
        visibleDayCount == 0
    }

    static func showsRefreshIndicator(isLoading: Bool, delayElapsed: Bool) -> Bool {
        isLoading && delayElapsed
    }

    static func showsInventoryFilters(mode: AutomationDashboardViewMode) -> Bool {
        mode == .all
    }
}

struct AutomationsDashboardView: View {
    let onSelectSessions: () -> Void
    let onOpenSettings: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode: AutomationDashboardViewMode = .upcoming
    @State private var filter: AutomationInventoryFilter = .all
    @State private var actionFilter: AutomationActionKind?
    @State private var serverFilter: String?
    @State private var search = ""
    @State private var showingSearch = false
    @State private var showingFilters = false
    @State private var selected: AutomationSummarySelection?
    @State private var createPresented = false
    @State private var selectedDate = Date.now
    @State private var datePickerPresented = false
    @State private var timeline: AutomationTimelineCoordinator?
    @State private var timelineRefreshIndicatorVisible = false

    private var eligibleProfileIDs: Set<String> {
        Set(model.automationCatalog.allEndpoints().map(\.id))
    }

    private var availableBuckets: [AutomationProfileCatalog] {
        model.automationCatalog.buckets.filter { eligibleProfileIDs.contains($0.id) }
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
        ZStack(alignment: .bottom) {
            ZStack(alignment: .bottomTrailing) {
                content
                TronTopBlurOverlay(style: .dashboard)
                dashboardBottomControls
                    .accessibilityHidden(showingSearch)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            if showingSearch {
                automationSearchBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.tronBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .tronPresentation()
        .tronSettingsVisualTheme(accent: .tronAutomation)
        .task(id: presentationActivity.allowsPresentationPublication) {
            guard presentationActivity.allowsPresentationPublication else { return }
            model.automationCatalog.activate()
            if timeline == nil {
                let coordinator = AutomationTimelineCoordinator(endpoints: { @MainActor in
                    model.automationCatalog.allEndpoints()
                })
                timeline = coordinator
                coordinator.load(start: selectedDate)
            }
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
            guard !Task.isCancelled,
                  AutomationTimelinePresentationPolicy.showsRefreshIndicator(
                    isLoading: timeline?.isLoading == true,
                    delayElapsed: true
                  ) else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                timelineRefreshIndicatorVisible = true
            }
        }
        .onChange(of: model.automationCatalog.buckets) { _, buckets in
            if let serverFilter,
               !buckets.contains(where: { $0.profile.id == serverFilter && eligibleProfileIDs.contains($0.id) }) {
                self.serverFilter = nil
            }
            if mode == .upcoming { timeline?.load(start: selectedDate) }
        }
        .onChange(of: mode) { _, nextMode in
            if nextMode == .upcoming {
                dismissAutomationSearch()
                timeline?.load(start: selectedDate)
            }
        }
        .onChange(of: model.profileRevision) { _, _ in
            model.automationCatalog.reload()
        }
        .onChange(of: model.connectionState) { _, _ in
            model.automationCatalog.reload()
        }
        .onDisappear {
            model.automationCatalog.deactivate()
            timeline?.cancel()
            timeline = nil
            timelineRefreshIndicatorVisible = false
        }
        .tronManagedSheet(item: $selected, identity: { "automation.detail.\($0.id)" }) { selection in
            AutomationDetailView(selection: selection)
        }
        .tronManagedSheet(isPresented: $createPresented, identity: "automation.create") {
            AutomationFormView(selection: nil, onSaved: { createPresented = false })
        }
        .tronManagedSheet(isPresented: $showingFilters, identity: "automation.filters") {
            automationFilterSheet
                .tronTopBlur(.sheet)
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
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
            .tronSettingsVisualTheme(accent: .tronAutomation)
        }
    }

    @ViewBuilder private var content: some View {
        if mode == .all { inventoryList } else { upcomingContent }
    }

    private var inventoryList: some View {
        ScrollView {
            LazyVStack(spacing: TronSpacing.md) {
                if model.automationCatalog.isLoading && summaries.isEmpty {
                    TronLoadingState(label: "Loading Automations…", accent: .tronAutomation).frame(minHeight: 240)
                } else if summaries.isEmpty {
                    inventoryEmptyState
                } else {
                    ForEach(summaries.map { AutomationSummarySelection(profileID: $0.profile.id, summary: $0.summary) }) { item in
                        if let profile = model.automationCatalog.buckets.first(where: { $0.profile.id == item.profileID })?.profile {
                            automationCard(profile, item.summary)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16).padding(.bottom, 80)
        }
        .refreshable { model.automationCatalog.reload() }
        .tronScrollEdgeChrome()
    }

    private var upcomingContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TronSpacing.md, pinnedViews: [.sectionHeaders]) {
                if attentionCount > 0 { attentionBanner }
                if AutomationTimelinePresentationPolicy.showsEmptyState(
                    visibleDayCount: visibleTimelineDays.count
                ) {
                    upcomingEmptyState
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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .padding(.bottom, 80)
        }
        .refreshable {
            model.automationCatalog.reload()
            timeline?.load(start: selectedDate)
        }
        .tronScrollEdgeChrome()
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
                    if let match = model.automationCatalog.summaries.first(where: { $0.profile.id == item.profileID && $0.summary.id == occurrence.automationId }) {
                        Text(match.summary.name).font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold)).foregroundStyle(Color.tronTextPrimary).lineLimit(1)
                        Text("\(match.summary.typedActionKind?.label ?? "Action") · \(targetLabel(profileID: item.profileID, sessionID: match.summary.targetSessionId))").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary).lineLimit(1)
                        Text(match.profile.label + (match.summary.trigger.kind == "calendar" ? " · \(match.summary.trigger.timezone ?? "")" : "")).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted).lineLimit(1)
                    } else { Text("Automation \(occurrence.automationId)").foregroundStyle(Color.tronTextSecondary) }
                    if occurrence.isSeries { Text("\(occurrence.count ?? 0) triggers · \(AutomationDateFormatting.date(occurrence.firstAt))–\(AutomationDateFormatting.date(occurrence.lastAt))").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted) }
                }
                Spacer(minLength: 0)
            }.padding(TronSpacing.lg)
        }.buttonStyle(.plain).tronGlassSurface(accent: .tronAutomation, cornerRadius: 14, tintOpacity: 0.08, interactive: true)
            .accessibilityLabel("Scheduled automation")
    }

    private func automationCard(_ profile: AutomationDashboardProfile, _ summary: GatewayAutomationSummary) -> some View {
        Button { selected = AutomationSummarySelection(profileID: profile.id, summary: summary) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: summary.typedActionKind?.icon ?? "clock").foregroundStyle(Color.tronAutomation).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(summary.name).font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold)).foregroundStyle(Color.tronTextPrimary).lineLimit(1); Spacer(); AutomationStatusBadge(activation: summary.activation, run: summary.currentRun?.state) }
                    Text(summary.trigger.summary).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
                    Text("\(summary.typedActionKind?.label ?? summary.actionKind) · \(targetLabel(profileID: profile.id, sessionID: summary.targetSessionId))").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted).lineLimit(1)
                    if let next = summary.nextOccurrenceAt {
                        Text("Next: \(AutomationDateFormatting.date(next))").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronAutomation)
                    } else if let last = summary.lastRun {
                        Text("Last: \(last.state.label) · \(AutomationDateFormatting.date(last.terminalAt ?? last.scheduledFor))")
                            .font(TronTypography.secondaryCodeDescription)
                            .foregroundStyle(last.state == .failed || last.state == .outcomeUnknown ? Color.tronError : Color.tronTextMuted)
                    }
                    if let reason = summary.blockedReason { Text(reason).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronError).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }.padding(TronSpacing.lg)
        }.buttonStyle(.plain).tronGlassSurface(accent: summary.isAttentionRequired ? .tronError : .tronAutomation, cornerRadius: 14, tintOpacity: summary.isAttentionRequired ? 0.13 : 0.08, interactive: true)
            .accessibilityLabel(AutomationStatusPresentation.accessible(summary))
    }

    private var attentionBanner: some View {
        Button {
            dismissAutomationSearch()
            actionFilter = nil
            filter = .attention
            mode = .all
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
        VStack(spacing: TronSpacing.md) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: 38, weight: .medium))
                .foregroundStyle(Color.tronTextMuted)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(TronTypography.headline)
                .foregroundStyle(Color.tronTextPrimary)
            Text(message)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.horizontal, TronSpacing.xl)
        .accessibilityElement(children: .combine)
    }

    private func targetLabel(profileID: String, sessionID: String) -> String {
        model.visibleSessions.first(where: {
            $0.id == sessionID && ($0.gatewayProfileID == profileID || ($0.gatewayProfileID == nil && profileID == model.profiles.selected?.id))
        })?.title ?? "Session \(sessionID)"
    }

    private var dashboardBottomControls: some View {
        HStack(alignment: .bottom) {
            if mode == .all {
                Button(action: showAutomationSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(TronTypography.sans(size: 22, weight: .semibold))
                }
                .buttonStyle(TronIconButtonStyle(accent: .tronAutomation, size: 56))
                .accessibilityLabel("Search Automations")
            } else {
                Button { datePickerPresented = true } label: {
                    Image(systemName: "calendar")
                }
                .buttonStyle(TronIconButtonStyle(accent: .tronAutomation, size: 56))
                .accessibilityLabel("Choose agenda date")
            }
            Spacer(minLength: 12)
            Button { createPresented = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(TronIconButtonStyle(accent: .tronAutomation, size: 56))
            .accessibilityLabel("Create Automation")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
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
        withAnimation(.snappy(duration: 0.18)) { showingSearch = true }
    }

    private func dismissAutomationSearch() {
        guard showingSearch || !search.isEmpty else { return }
        withAnimation(.snappy(duration: 0.18)) {
            search = ""
            showingSearch = false
        }
    }

    private var automationFilterSheet: some View {
        TronDashboardFilterSheet(
            title: "View Automations",
            accent: .tronAutomation,
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
                    mode = option
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
                            filter = option
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
                        actionFilter = nil
                    }
                    ForEach(AutomationActionKind.allCases, id: \.self) { action in
                        TronDashboardFilterOption(
                            title: action.label,
                            selected: actionFilter == action,
                            accent: .tronAutomation,
                            inactiveAccent: .tronSlate
                        ) {
                            actionFilter = action
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
                    serverFilter = nil
                }
                ForEach(availableBuckets) { bucket in
                    TronDashboardFilterOption(
                        title: bucket.profile.label,
                        detail: "Connected",
                        selected: serverFilter == bucket.profile.id,
                        accent: .tronAutomation,
                        inactiveAccent: .tronSlate
                    ) {
                        serverFilter = bucket.profile.id
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            DashboardModeMenuButton(mode: .automations) { selected in if selected == .sessions { onSelectSessions() } }.frame(width: 34, height: 34)
        }
        ToolbarItem(placement: .principal) {
            Text("Automations")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold))
                .foregroundStyle(Color.tronAutomation)
                .overlay(alignment: .trailing) {
                    if mode == .upcoming && timelineRefreshIndicatorVisible {
                        TronPulseLoadingIndicator(accent: .tronAutomation, size: 14)
                            .offset(x: 22)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Refreshing upcoming Automations")
                            .transition(.opacity)
                    }
                }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showingFilters = true } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    .foregroundStyle(Color.tronAutomation)
            }
            .accessibilityLabel("View and filter Automations, \(mode.rawValue)")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").foregroundStyle(Color.tronAutomation)
            }
            .accessibilityLabel("Settings")
        }
    }
}
