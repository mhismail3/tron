import SwiftUI

struct AutomationSummarySelection: Hashable, Identifiable {
    let profileID: String
    let summary: GatewayAutomationSummary
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

struct AutomationsDashboardView: View {
    let onSelectSessions: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: AutomationDashboardViewMode = .upcoming
    @State private var filter: AutomationInventoryFilter = .all
    @State private var actionFilter: AutomationActionKind?
    @State private var serverFilter: String?
    @State private var search = ""
    @State private var selected: AutomationSummarySelection?
    @State private var createPresented = false
    @State private var selectedDate = Date.now
    @State private var datePickerPresented = false
    @State private var timeline: AutomationTimelineCoordinator?

    private var summaries: [(profile: AutomationDashboardProfile, summary: GatewayAutomationSummary)] {
        model.automationCatalog.summaries.filter { profile, summary in
            (serverFilter == nil || serverFilter == profile.id)
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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            Button { createPresented = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(TronIconButtonStyle(size: 56))
            .accessibilityLabel("Create automation")
            .padding(.trailing, 20)
            .padding(.bottom, 12)
        }
        .background(Color.tronBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .tronPresentation()
        .task(id: presentationActivity.allowsPresentationPublication) {
            guard presentationActivity.allowsPresentationPublication else { return }
            model.automationCatalog.reload()
            if timeline == nil {
                timeline = AutomationTimelineCoordinator(endpoints: { @MainActor in
                    model.automationCatalog.allEndpoints()
                })
            }
            timeline?.load(start: selectedDate)
        }
        .onChange(of: model.automationCatalog.buckets) { _, _ in
            if mode == .upcoming { timeline?.load(start: selectedDate) }
        }
        .onDisappear {
            model.automationCatalog.cancel()
            timeline?.cancel()
        }
        .tronManagedSheet(item: $selected, identity: { "automation.detail.\($0.id)" }) { selection in
            AutomationDetailView(selection: selection)
        }
        .tronManagedSheet(isPresented: $createPresented, identity: "automation.create") {
            AutomationFormView(selection: nil, onSaved: { createPresented = false })
        }
        .tronManagedSheet(isPresented: $datePickerPresented, identity: "automation.date-picker") {
            NavigationStack {
                DatePicker("Start date", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .tronNavigationTitle("Jump to date", accent: .tronCoral)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { datePickerPresented = false; timeline?.load(start: selectedDate) } label: { Image(systemName: "checkmark") }
                                .accessibilityLabel("Done")
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            modeControl
            if mode == .all { allContent } else { upcomingContent }
        }
    }

    private var modeControl: some View {
        TronSegmentedControl(options: AutomationDashboardViewMode.allCases.map { ($0.rawValue, $0) }, selection: $mode)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityLabel("Automation dashboard view")
    }

    @ViewBuilder private var allContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TronSearchBar(text: $search, prompt: "Search automations")
                Menu {
                    ForEach(AutomationInventoryFilter.allCases) { option in
                        Button { filter = option } label: { Label(option.rawValue, systemImage: filter == option ? "checkmark" : "") }
                    }
                    Divider()
                    Button("All action types") { actionFilter = nil }
                    ForEach(AutomationActionKind.allCases, id: \.self) { action in
                        Button(action.label) { actionFilter = action }
                    }
                    Divider()
                    Button("All servers") { serverFilter = nil }
                    ForEach(model.automationCatalog.buckets) { bucket in
                        Button(bucket.profile.label) { serverFilter = bucket.profile.id }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(TronTypography.buttonSM)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Filter automations")
            }
            .padding(.horizontal, 20)
            inventoryList
        }
    }

    private var inventoryList: some View {
        ScrollView {
            LazyVStack(spacing: TronSpacing.md) {
                if model.automationCatalog.isLoading && summaries.isEmpty {
                    TronLoadingState(label: "Loading Automations…", accent: .tronCoral).frame(minHeight: 240)
                } else if summaries.isEmpty {
                    automationEmptyState
                } else {
                    ForEach(Array(summaries.enumerated()), id: \.offset) { _, item in automationCard(item.profile, item.summary) }
                }
                failureView
            }
            .padding(.horizontal, 20).padding(.vertical, 16).padding(.bottom, 80)
        }
        .tronScrollEdgeChrome()
    }

    @ViewBuilder private var upcomingContent: some View {
        if let timeline, timeline.errorMessage != nil && timeline.days.isEmpty {
            VStack(spacing: TronSpacing.lg) {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 42)).foregroundStyle(Color.tronAmber)
                Text(timeline.errorMessage ?? "Upcoming is unavailable").font(TronTypography.headline).foregroundStyle(Color.tronTextPrimary).multilineTextAlignment(.center)
                Text("The All view remains available while this Gateway is updated or reconnects.").font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary).multilineTextAlignment(.center)
                Button("Open All") { mode = .all }.buttonStyle(TronActionButtonStyle(role: .primary))
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.md, pinnedViews: [.sectionHeaders]) {
                    if timeline?.isLoading == true && timeline?.days.isEmpty == true { TronLoadingState(label: "Loading upcoming triggers…", accent: .tronCoral).frame(minHeight: 220) }
                    else if timeline?.days.isEmpty == true { upcomingEmptyState }
                    else {
                        ForEach(timeline?.days ?? []) { day in
                            Section {
                                ForEach(day.items) { item in occurrenceRow(item) }
                            } header: { dayHeader(day.date, count: day.items.count) }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12).padding(.bottom, 80)
            }.tronScrollEdgeChrome()
        }
    }

    private func occurrenceTime(_ value: String) -> String {
        guard let date = GatewayTimestamp.parse(value) else { return "—" }
        let formatter = DateFormatter(); formatter.timeStyle = .short; return formatter.string(from: date)
    }

    private func dayHeader(_ date: Date, count: Int) -> some View {
        let calendar = Calendar.current
        let title = calendar.isDateInToday(date) ? "Today" : calendar.isDateInTomorrow(date) ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return HStack { Text(title).font(TronTypography.sheetSectionHeader).foregroundStyle(Color.tronCoral); Spacer(); Text("\(count) trigger\(count == 1 ? "" : "s")").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted) }
            .padding(.vertical, 6).background(Color.tronBackground.opacity(0.96))
    }

    private func occurrenceRow(_ item: AutomationTimelineItem) -> some View {
        let occurrence = item.occurrence
        return Button {
            if let summary = model.automationCatalog.summaries.first(where: { $0.profile.id == item.profileID && $0.summary.id == occurrence.automationId }) {
                selected = AutomationSummarySelection(profileID: summary.profile.id, summary: summary.summary)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(occurrenceTime(occurrence.scheduledFor)).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronCoral).frame(width: 64, alignment: .leading)
                Image(systemName: occurrence.isSeries ? "repeat" : "circle.fill").foregroundStyle(Color.tronCoral).padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    if let match = model.automationCatalog.summaries.first(where: { $0.profile.id == item.profileID && $0.summary.id == occurrence.automationId }) {
                        Text(match.summary.name).font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold)).foregroundStyle(Color.tronTextPrimary).lineLimit(1)
                        Text("\(match.summary.typedActionKind?.label ?? "Action") · Session \(match.summary.targetSessionId)").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary).lineLimit(1)
                        Text(match.profile.label + (match.summary.trigger.kind == "calendar" ? " · \(match.summary.trigger.timezone ?? "")" : "")).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted).lineLimit(1)
                    } else { Text("Automation \(occurrence.automationId)").foregroundStyle(Color.tronTextSecondary) }
                    if occurrence.isSeries { Text("\(occurrence.count ?? 0) triggers · \(AutomationDateFormatting.date(occurrence.firstAt))–\(AutomationDateFormatting.date(occurrence.lastAt))").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted) }
                }
                Spacer(minLength: 0); Image(systemName: "chevron.right").foregroundStyle(Color.tronTextMuted)
            }.padding(TronSpacing.lg)
        }.buttonStyle(.plain).tronGlassSurface(accent: .tronCoral, cornerRadius: 14, tintOpacity: 0.08, interactive: true)
            .accessibilityLabel("Scheduled automation")
    }

    private func automationCard(_ profile: AutomationDashboardProfile, _ summary: GatewayAutomationSummary) -> some View {
        Button { selected = AutomationSummarySelection(profileID: profile.id, summary: summary) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: summary.typedActionKind?.icon ?? "clock").foregroundStyle(Color.tronCoral).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(summary.name).font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold)).foregroundStyle(Color.tronTextPrimary).lineLimit(1); Spacer(); AutomationStatusBadge(activation: summary.activation, run: summary.currentRun?.state) }
                    Text(summary.trigger.summary).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
                    Text("\(summary.typedActionKind?.label ?? summary.actionKind) · Session \(summary.targetSessionId)").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextMuted).lineLimit(1)
                    if profile.state != .connected { Label("Cached · \(profile.state.label)", systemImage: "wifi.slash").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronAmber) }
                    if let next = summary.nextOccurrenceAt { Text("Next: \(AutomationDateFormatting.date(next))").font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronCoral) }
                    if let reason = summary.blockedReason { Text(reason).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronError).lineLimit(2) }
                }
                Image(systemName: "chevron.right").foregroundStyle(Color.tronTextMuted).padding(.top, 4)
            }.padding(TronSpacing.lg)
        }.buttonStyle(.plain).tronGlassSurface(accent: summary.isAttentionRequired ? .tronError : .tronCoral, cornerRadius: 14, tintOpacity: summary.isAttentionRequired ? 0.13 : 0.08, interactive: true)
            .accessibilityLabel(AutomationStatusPresentation.accessible(summary))
    }

    @ViewBuilder private var failureView: some View {
        if let failure = model.automationCatalog.errorMessage { Label(failure, systemImage: "exclamationmark.triangle").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronAmber).padding() }
    }
    private var automationEmptyState: some View { emptyState(icon: "clock.badge.checkmark", title: "No Automations", message: "Create a durable prompt or notification schedule for a persisted session.") }
    private var upcomingEmptyState: some View { emptyState(icon: "calendar", title: "Nothing upcoming", message: "Enable an automation or create a new repeating schedule to see it here.") }
    private func emptyState(icon: String, title: String, message: String) -> some View { VStack(spacing: 12) { Image(systemName: icon).font(.system(size: 42)).foregroundStyle(Color.tronTextMuted); Text(title).font(TronTypography.headline).foregroundStyle(Color.tronTextPrimary); Text(message).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, minHeight: 280).padding(24) }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            DashboardModeMenuButton(mode: .automations) { selected in if selected == .sessions { onSelectSessions() } }.frame(width: 34, height: 34)
        }
        ToolbarItem(placement: .principal) { Text("Automations").font(TronTypography.sans(size: TronTypography.sizeXL, weight: .bold)).foregroundStyle(Color.tronCoral) }
        ToolbarItemGroup(placement: .primaryAction) {
            if mode == .upcoming { Button { datePickerPresented = true } label: { Image(systemName: "calendar") }.accessibilityLabel("Choose agenda date") }
            Button { model.automationCatalog.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh automations")
        }
    }
}
