import SwiftUI
import TronMobileCore

struct AutomationSummarySelection: Hashable, Identifiable {
    let profileID: String
    let summary: GatewayAutomationSummary
    var id: String { "\(profileID):\(summary.id)" }
}

extension View {
    /// The one Automations presentation, opened from the dashboard menu. The
    /// shell owns whether it is shown and the persisted list filters; the sheet
    /// owns its search, filter, create and detail presentations.
    func automationsSheet(
        isPresented: Binding<Bool>,
        preferences: Binding<AutomationDashboardViewPreferences>,
        onOpenSession: @escaping @MainActor (String, String) -> Void
    ) -> some View {
        tronManagedSheet(isPresented: isPresented, identity: "dashboard.automations") {
            AutomationsSheet(
                viewPreferences: preferences,
                onOpenSession: onOpenSession,
                onDone: { isPresented.wrappedValue = false }
            )
        }
    }
}

/// Searchable, filterable inventory of every connected Gateway's Automations.
struct AutomationsSheet: View {
    let onOpenSession: @MainActor (String, String) -> Void
    let onDone: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var viewPreferences: AutomationDashboardViewPreferences
    @PresentationState private var search = ""
    @PresentationState private var showingSearch = false
    @PresentationState private var showingFilters = false
    @PresentationState private var selected: AutomationSummarySelection?
    @PresentationState private var createPresented = false

    init(
        viewPreferences: Binding<AutomationDashboardViewPreferences>,
        onOpenSession: @escaping @MainActor (String, String) -> Void,
        onDone: @escaping () -> Void
    ) {
        _viewPreferences = viewPreferences
        self.onOpenSession = onOpenSession
        self.onDone = onDone
    }

    private var eligibleProfileIDs: Set<String> {
        Set(model.automationCatalog.allEndpoints().map(\.id))
    }

    private var availableBuckets: [AutomationProfileCatalog] {
        model.automationCatalog.buckets.filter { eligibleProfileIDs.contains($0.id) }
    }

    private var filter: AutomationInventoryFilter { viewPreferences.inventoryFilter }
    private var actionFilter: AutomationActionKind? { viewPreferences.actionFilter }
    private var serverFilter: String? {
        viewPreferences.effectiveProfileID(eligibleProfileIDs: eligibleProfileIDs)
    }
    private var isFiltered: Bool { filter != .all || actionFilter != nil || serverFilter != nil }
    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var summarySelections: [AutomationSummarySelection] {
        model.automationCatalog.summaries.filter { profile, summary in
            eligibleProfileIDs.contains(profile.id)
                && (serverFilter == nil || serverFilter == profile.id)
                && filter.matches(summary)
                && (actionFilter == nil || summary.typedActionKind == actionFilter)
                && (trimmedSearch.isEmpty || summary.name.localizedCaseInsensitiveContains(trimmedSearch))
        }.sorted { left, right in
            let attention = (left.summary.isAttentionRequired ? 0 : 1, right.summary.isAttentionRequired ? 0 : 1)
            if attention.0 != attention.1 { return attention.0 < attention.1 }
            let running = (left.summary.currentRun?.state == .running ? 0 : 1, right.summary.currentRun?.state == .running ? 0 : 1)
            if running.0 != running.1 { return running.0 < running.1 }
            return (left.summary.nextOccurrenceAt ?? "9999", left.summary.name) < (right.summary.nextOccurrenceAt ?? "9999", right.summary.name)
        }.map { AutomationSummarySelection(profileID: $0.profile.id, summary: $0.summary) }
    }

    var body: some View {
        TronDashboardFilterSheet(
            title: "Automations",
            accent: .tronAutomation,
            detents: [.medium, .large],
            onDone: onDone
        ) {
            Button { createPresented = true } label: {
                Image(systemName: "plus").font(TronTypography.buttonSM)
            }
            .tronToolbarAction(accent: .tronAutomation)
            .accessibilityLabel("New Automation")
            .accessibilityIdentifier("automations.new")
            Button { showingFilters = true } label: {
                Image(systemName: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .font(TronTypography.buttonSM)
            }
            .tronToolbarAction(accent: .tronAutomation)
            .accessibilityLabel("Filter")
            .accessibilityValue(isFiltered ? "Filtered" : "All")
            .accessibilityIdentifier("automations.filter")
        } content: {
            content
                // The floating search control must never cover the last row.
                .padding(.bottom, 64)
        }
        .overlay(alignment: .bottomTrailing) { searchChrome }
        .animation(.snappy(duration: 0.18), value: showingSearch)
        .task(id: PresentationActivityTaskID(
            source: scenePhase,
            presentationActive: presentationActivity.allowsDataPublication
        )) {
            // Descendant detail/form sheets consume the same narrow catalog's
            // revisions, so the catalog stays active beneath them.
            if presentationActivity.allowsDataPublication, scenePhase == .active {
                if presentationActivity.allowsPresentationPublication { reconcileViewPreferences() }
                model.automationCatalog.activate()
            } else {
                model.automationCatalog.deactivate()
            }
        }
        .onChange(of: model.profileRevision) { _, _ in
            if presentationActivity.allowsPresentationPublication { reconcileViewPreferences() }
            model.automationCatalog.invalidate()
        }
        .onChange(of: model.connectionState) { _, _ in
            model.automationCatalog.invalidate()
        }
        .onDisappear { model.automationCatalog.deactivate() }
        .tronManagedSheet(item: $selected, identity: { "automation.detail.\($0.id)" }) { selection in
            AutomationDetailView(selection: selection, onOpenSession: onOpenSession)
        }
        .tronManagedSheet(isPresented: $createPresented, identity: "automation.create") {
            AutomationFormView(selection: nil, onSaved: { createPresented = false })
        }
        .tronManagedSheet(isPresented: $showingFilters, identity: "automation.filters") {
            automationFilterSheet
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.automationCatalog.hasLoaded {
            TronLoadingState(label: "Loading Automations", accent: .tronAutomation)
                .frame(minHeight: 200)
        } else if summarySelections.isEmpty {
            TronPlaceholderState(
                title: isFiltered || !trimmedSearch.isEmpty ? "No matches" : "No Automations",
                detail: isFiltered || !trimmedSearch.isEmpty
                    ? "Adjust the search or filters to show more Automations."
                    : "Create a durable prompt or notification schedule for a persisted session.",
                icon: isFiltered || !trimmedSearch.isEmpty ? "line.3.horizontal.decrease.circle" : "clock.badge.checkmark",
                accent: .tronAutomation
            )
            .transition(.opacity)
        } else {
            LazyVStack(spacing: TronSpacing.md) {
                ForEach(summarySelections) { item in
                    if let profile = model.automationCatalog.buckets.first(where: { $0.profile.id == item.profileID })?.profile {
                        automationCard(profile, item)
                            .transition(.opacity)
                    }
                }
            }
            .animation(
                TronDashboardContentMotion.animation(reduceMotion: reduceMotion),
                value: summarySelections
            )
        }
    }

    private func automationCard(_ profile: AutomationDashboardProfile, _ item: AutomationSummarySelection) -> some View {
        let summary = item.summary
        let presentation = AutomationSummaryPresentation(summary: summary, server: profile.label)
        return Button { selected = item } label: {
            AutomationSummaryCard(presentation: presentation)
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
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var searchChrome: some View {
        if showingSearch {
            TronSearchBar(
                text: $search,
                prompt: "Search Automations",
                accent: .tronAutomation,
                focusOnAppear: true,
                onClose: dismissSearch,
                // Scrolling the results dismisses the keyboard; only an empty
                // query closes the pill with it.
                onFocusChange: { focused in
                    if !focused && trimmedSearch.isEmpty { dismissSearch() }
                }
            )
            .padding(.horizontal, TronSpacing.section)
            .padding(.vertical, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            Button { showingSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(TronTypography.sans(size: 22, weight: .semibold))
                    .foregroundStyle(Color.tronAutomation)
                    .tronDashboardFloatingCircle(accent: .tronAutomation)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityLabel("Search Automations")
            .accessibilityIdentifier("automations.search")
            .transition(.scale(scale: 0.72).combined(with: .opacity))
        }
    }

    private func dismissSearch() {
        search = ""
        showingSearch = false
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
            title: "Filter",
            accent: .tronAutomation,
            detents: [.medium, .large],
            onDone: { showingFilters = false }
        ) {
            TronDashboardFilterSectionTitle(
                title: "Status",
                detail: "Limit the list by lifecycle state."
            )
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
