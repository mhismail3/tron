import SwiftUI
import TronMobileCore

struct AutomationSummarySelection: Hashable, Identifiable {
    let profileID: String
    let summary: GatewayAutomationSummary
    var id: String { "\(profileID):\(summary.id)" }
}

extension View {
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

struct AutomationsSheet: View {
    let onOpenSession: @MainActor (String, String) -> Void
    let onDone: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding private var viewPreferences: AutomationDashboardViewPreferences
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

    var body: some View {
        let rows = AutomationInventory.rows(
            buckets: model.automationCatalog.buckets, eligibleProfileIDs: eligibleProfileIDs,
            profileID: serverFilter, filter: filter, action: actionFilter
        )
        TronDashboardFilterSheet(
            title: "Automations",
            accent: .tronPrimary,
            detents: [.medium, .large],
            onDone: onDone
        ) {
            Button { createPresented = true } label: {
                Image(systemName: "plus").font(TronTypography.buttonSM)
            }
            .tronToolbarAction(accent: .tronPrimary)
            .accessibilityLabel("New Automation")
            .accessibilityIdentifier("automations.new")
        } content: {
            content(rows)
                .padding(.bottom, 64)
        }
        .overlay(alignment: .bottomTrailing) {
            DashboardFloatingButton(
                symbol: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                accent: .tronPrimary,
                label: "Filter",
                identifier: "automations.filter",
                value: isFiltered ? "Filtered" : "All"
            ) { showingFilters = true }
        }
        .task(id: PresentationActivityTaskID(
            source: scenePhase,
            presentationActive: presentationActivity.allowsDataPublication
        )) {
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
    private func content(_ rows: [AutomationInventoryRow]) -> some View {
        if !model.automationCatalog.hasLoaded {
            TronLoadingState(label: "Loading Automations", accent: .tronPrimary)
                .frame(minHeight: 200)
        } else if rows.isEmpty {
            TronPlaceholderState(
                title: isFiltered ? "No matches" : "No Automations",
                detail: isFiltered
                    ? "Adjust the filters to show more Automations."
                    : "Create a durable prompt or notification schedule for a persisted session.",
                icon: isFiltered ? "line.3.horizontal.decrease.circle" : "clock.badge.checkmark",
                accent: .tronPrimary
            )
            .transition(.opacity)
        } else {
            AutomationInventoryList(rows: rows) { selected = $0 }
                .equatable()
                .animation(TronDashboardContentMotion.animation(reduceMotion: reduceMotion), value: rows.map(\.id))
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
            guard profile.isEnabled, (try? model.profiles.token(for: profile)) != nil else { return nil }
            return profile.id
        })
        guard next != viewPreferences else { return }
        viewPreferences = next
    }

    private var automationFilterSheet: some View {
        TronDashboardFilterSheet(
            title: "Filter",
            accent: .tronPrimary,
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
                    accent: .tronPrimary,
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
                accent: .tronPrimary,
                inactiveAccent: .tronSlate
            ) {
                updateViewPreferences { $0.actionFilter = nil }
            }
            ForEach(AutomationActionKind.allCases, id: \.self) { action in
                TronDashboardFilterOption(
                    title: action.label,
                    selected: actionFilter == action,
                    accent: .tronPrimary,
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
                    accent: .tronPrimary,
                    inactiveAccent: .tronSlate
                ) {
                    updateViewPreferences { $0.selectedProfileID = nil }
                }
                ForEach(availableBuckets) { bucket in
                    TronDashboardFilterOption(
                        title: bucket.profile.label,
                        detail: "Connected",
                        selected: serverFilter == bucket.profile.id,
                        accent: .tronPrimary,
                        inactiveAccent: .tronSlate
                    ) {
                        updateViewPreferences { $0.selectedProfileID = bucket.profile.id }
                    }
                }
            }
        }
    }
}

private struct AutomationInventoryList: View, Equatable {
    let rows: [AutomationInventoryRow]
    let onSelect: (AutomationSummarySelection) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.rows == rhs.rows }

    var body: some View {
        LazyVStack(spacing: TronListMetrics.feedGap) {
            ForEach(rows) { row in
                TronFeedCard {
                    Button { onSelect(row.selection) } label: { TronListRow(row.content) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.accessibilityLabel)
                        .accessibilityIdentifier("automation-card.\(row.selection.summary.id)")
                }
                .transition(.opacity)
            }
        }
    }
}
