import SwiftUI

struct ExtensionActivityRoute: Identifiable, Hashable {
    let id: String
    let mountedActivity: ExtensionRunActivity?

    init(id: String, mountedActivity: ExtensionRunActivity? = nil) {
        self.id = id
        self.mountedActivity = mountedActivity
    }
}

/// One compact, composer-adjacent affordance per opaque widget group. Groups
/// are intentionally not inferred from package names or display text.
enum ExtensionActivityHubSection: CaseIterable, Sendable {
    case overview, currentWork, recentlyFinished, extensionUpdates, serviceActivity, viewAllActivity

    var title: String {
        switch self {
        case .overview: "Overview"
        case .currentWork: "Current Work"
        case .recentlyFinished: "Recently Finished"
        case .extensionUpdates: "Extension Updates"
        case .serviceActivity: "Service Activity"
        case .viewAllActivity: "View All Activity"
        }
    }
}

struct ExtensionActivityPillTransitionState: Equatable, Sendable {
    private(set) var token = 0
    private(set) var target: ExtensionActivityPillVisualState?

    mutating func retarget(_ value: ExtensionActivityPillVisualState) -> Int {
        token &+= 1
        target = value
        return token
    }

    func admits(_ candidate: Int) -> Bool { candidate == token }
}

struct ExtensionActivityPill: View {
    let group: ExtensionWidgetGroup
    let onTap: () -> Void
    var onVisualState: ((ExtensionActivityPillVisualState, Int) -> Void)? = nil
    var onExpiry: ((String, ExtensionActivityVisibility, Int?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedState: ExtensionActivityPillVisualState?
    @State private var transitionState = ExtensionActivityPillTransitionState()
    @State private var transitionTask: Task<Void, Never>?
    @State private var expiryTask: Task<Void, Never>?
    @State private var visualDeadline: ExtensionActivityVisualDeadline?
    @State private var visualDeadlineExpired = false

    private var targetState: ExtensionActivityPillVisualState {
        ExtensionActivityPillPolicy.state(for: group)
    }

    var body: some View {
        let visual = displayedState ?? targetState
        Group {
            if !visualDeadlineExpired {
                Button(action: onTap) {
                    ChatCompactPillSurface(
                        tone: visual.tone,
                        material: .glass,
                        interactive: true
                    ) {
                        ChatCompactPillLabel(
                            icon: visual.symbol,
                            title: visual.title,
                            detail: visual.detail,
                            tone: visual.tone,
                            showsProgress: visual.showsProgress,
                            iconSize: ChatCompactPillLayoutPolicy.standardIconSize
                        ) {
                            if visual.count > 1 {
                                Text("\(visual.count)")
                                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .bold))
                                    .foregroundStyle(visual.tone.secondaryColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentTransition(reduceMotion ? .opacity : .interpolate)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(visual.accessibilityLabel)
                .accessibilityHint("Opens extension activity")
                .accessibilityIdentifier("extension-pill-\(visual.ownerID)")
            }
        }
        .onAppear {
            let token = transitionState.retarget(targetState)
            displayedState = targetState
            onVisualState?(targetState, token)
            refreshExpiry()
        }
        .onChange(of: targetState) { _, target in
            retarget(target)
            refreshExpiry()
        }
        .onChange(of: group) { _, _ in refreshExpiry() }
        .onDisappear {
            transitionTask?.cancel()
            expiryTask?.cancel()
            transitionTask = nil
            expiryTask = nil
        }
    }

    private func retarget(_ target: ExtensionActivityPillVisualState) {
        transitionTask?.cancel()
        let token = transitionState.retarget(target)
        // One task per owner is coalesced to the next display frame. This is
        // intentionally the same shallow transition contract as tool chips.
        transitionTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !Task.isCancelled, transitionState.admits(token) else { return }
            var transaction = Transaction(animation: reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.20))
            transaction.admitsChatToolChipAnimation = true
            withTransaction(transaction) { displayedState = target }
            onVisualState?(target, token)
        }
    }

    private func refreshExpiry() {
        expiryTask?.cancel()
        visualDeadlineExpired = false
        guard let activity = group.activities.first,
              let lifecycle = activity.lifecycle,
              let bucket = lifecycle.visibility else {
            visualDeadline = nil
            return
        }
        let deadline = ExtensionActivityVisualDeadline(bucket: bucket, remainingMs: lifecycle.remainingMs)
        visualDeadline = deadline
        onExpiry?(group.id, bucket, lifecycle.remainingMs)
        guard bucket == .recent, let remainingMs = lifecycle.remainingMs, remainingMs > 0 else { return }
        // This is a rendering failsafe only. The Gateway bucket remains the
        // authority; a stale recent frame may not keep a pill mounted forever.
        expiryTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(remainingMs)) } catch { return }
            guard !Task.isCancelled, visualDeadline?.expired(at: .now) == true else { return }
            visualDeadlineExpired = true
            onExpiry?(group.id, bucket, 0)
        }
    }
}

struct ExtensionDetailsSheet: View {
    let sessionID: String
    let groupID: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    init(sessionID: String, groupID: String? = nil) { self.sessionID = sessionID; self.groupID = groupID }

    private var snapshot: SessionSnapshot? { model.authoritativeSnapshot(for: sessionID) }
    private var presentation: ExtensionPresentationState? { snapshot?.extensionPresentation }
    private var groups: [ExtensionWidgetGroup] {
        guard let presentation else { return [] }
        return ChatExtensionWidgetPolicy.groups(
            presentation,
            executions: snapshot?.toolExecutions ?? [],
            activities: snapshot?.extensionActivities ?? []
        )
    }
    private var selectedGroup: ExtensionWidgetGroup? {
        guard let groupID else { return nil }
        return groups.first(where: { $0.id == groupID })
    }
    private var isExpanded: Bool { presentation?.semanticState.toolsExpanded ?? false }
    var body: some View { activityHub }

    private var activityHub: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.lg) {
                    hubOverview
                    hubCurrentWork
                    hubRecentlyFinished
                    hubExtensionUpdates
                    hubServiceActivity
                    hubHistoryLink
                }
                .padding(.horizontal, TronSpacing.section)
                .padding(.top, TronSpacing.md).padding(.bottom, TronSpacing.xl)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: selectedGroup?.label ?? "Extension Activity") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.tronEmerald)
                }
            }
        }
        .navigationDestination(for: ExtensionActivityRoute.self) { route in
            ExtensionRunDetailsSheet(
                sessionID: sessionID,
                activityID: route.id,
                activityOverride: route.mountedActivity
            )
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .accessibilityIdentifier("extension-details-sheet")
    }

    private var hubGroups: [ExtensionWidgetGroup] {
        if let selectedGroup { return [selectedGroup] }
        return groups
    }

    private var hubActivities: [ExtensionRunActivity] {
        ChatExtensionWidgetPolicy.orderedActivities(hubGroups.flatMap(\.activities))
    }

    private var currentActivities: [ExtensionRunActivity] {
        hubActivities.filter { $0.lifecycle?.state.isCurrent == true || ($0.lifecycle == nil && $0.status == .running) }
    }

    private var recentActivities: [ExtensionRunActivity] {
        hubActivities.filter { activity in
            guard activity.lifecycle?.isTerminal == true || activity.status != .running else { return false }
            return activity.lifecycle?.visibility == .recent || activity.lifecycle == nil || activity.lifecycle?.visibility == .unknown
        }
    }

    private var hubServices: [ExtensionActivityServiceItem] {
        var seen = Set<String>()
        return hubGroups.flatMap(\.services).filter { seen.insert($0.id).inserted }
    }

    @ViewBuilder private var hubOverview: some View {
        hubSection("Overview", detail: "A bounded view of extension work, updates, and services.", accent: .tronEmerald) {
            VStack(alignment: .leading, spacing: 10) {
                Text(hubActivities.isEmpty && hubGroups.flatMap(\.items).isEmpty ? "No active extension work" : "Extension activity is grouped by its exact owner.")
                    .font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                    overviewMetric("Current", currentActivities.count)
                    overviewMetric("Finished", recentActivities.count)
                    overviewMetric("Updates", hubGroups.reduce(0) { $0 + $1.items.count + $1.statuses.count })
                    overviewMetric("Services", hubServices.count)
                }
            }
        }
    }

    @ViewBuilder private var hubCurrentWork: some View {
        hubSection("Current Work", detail: "Live runs and their latest bounded progress.", accent: .tronTeal) {
            if currentActivities.isEmpty { emptyHubRow("No current extension work", systemImage: "circle") }
            else { ForEach(currentActivities) { activityRow($0, accent: .tronTeal, fetchDetail: false) } }
        }
    }

    @ViewBuilder private var hubRecentlyFinished: some View {
        hubSection("Recently Finished", detail: "Terminal work retained in the mounted projection.", accent: .tronAmber) {
            if recentActivities.isEmpty { emptyHubRow("Nothing recently finished", systemImage: "checkmark.circle") }
            else { ForEach(recentActivities) { activityRow($0, accent: .tronAmber, fetchDetail: false) } }
        }
    }

    @ViewBuilder private var hubExtensionUpdates: some View {
        hubSection("Extension Updates", detail: "Statuses and widgets published by each owner.", accent: .tronCyan) {
            let updateGroups = hubGroups.filter { !$0.statuses.isEmpty || !$0.items.isEmpty }
            if updateGroups.isEmpty { emptyHubRow("No extension updates", systemImage: "rectangle.dashed") }
            else {
                ForEach(updateGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.label).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
                        if !group.statuses.isEmpty { statusRows(group.statuses) }
                        ForEach(group.items) { item in
                            switch item.content {
                            case .semantic(let widget): ExtensionWidgetView(widget: widget, isExpanded: isExpanded) { toggleExpanded() }
                            case .surface(let surface): ExtensionSurfaceWidgetView(surface: surface, isExpanded: isExpanded) { toggleExpanded() }
                            }
                        }
                    }
                    .padding(12).tronGlassSurface(accent: .tronCyan, tintOpacity: 0.08)
                }
            }
        }
    }

    @ViewBuilder private var hubServiceActivity: some View {
        hubSection("Service Activity", detail: "Extension tools remain outside the conversation transcript.", accent: .tronTeal) {
            if hubServices.isEmpty { emptyHubRow("No service activity", systemImage: "wrench.and.screwdriver") }
            else { serviceRows(hubServices) }
        }
    }

    @ViewBuilder private var hubHistoryLink: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("View All Activity")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(Color.tronTextPrimary)
            Text("Open canonical history, grouped separately from mounted current work.")
                .font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
            NavigationLink {
                ExtensionActivityHistorySheet(sessionID: sessionID)
            } label: {
                Label("View All Activity", systemImage: "clock.arrow.circlepath")
                    .font(TronTypography.bodySM).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).tronGlassSurface(accent: .tronCyan, tintOpacity: 0.12, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("extension-view-all-activity")
        }
        .accessibilityIdentifier("extension-activity-section-view-all")
    }

    private func hubSection<Content: View>(_ title: String, detail: String, accent: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold)).foregroundStyle(Color.tronTextPrimary)
            Text(detail).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(14)
        .tronGlassSurface(accent: accent, tintOpacity: 0.08)
        .accessibilityIdentifier("extension-activity-section-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private func overviewMetric(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)").font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold)).foregroundStyle(Color.tronTextPrimary)
            Text(title).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }

    private func emptyHubRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }

    private func statusRows(_ statuses: [ExtensionActivityStatus]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(statuses) { status in
                HStack(alignment: .top, spacing: 8) {
                    Text(status.displayKey).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
                    Text(status.value).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine).accessibilityLabel("\(status.key): \(status.value)")
            }
        }
    }

    private func serviceRows(_ services: [ExtensionActivityServiceItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(services) { service in
                HStack(spacing: 10) {
                    Image(systemName: service.error ? "exclamationmark.triangle.fill" : (service.status == "Running" ? "circle.dotted" : "checkmark.circle"))
                        .foregroundStyle(service.error ? Color.tronError : Color.tronTeal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.title).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).lineLimit(1)
                        Text("\(service.status) · \(service.source)").font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine).accessibilityLabel("\(service.title), \(service.status)")
            }
        }
    }

    private func activityRow(_ activity: ExtensionRunActivity, accent: Color, fetchDetail: Bool) -> some View {
        NavigationLink(value: ExtensionActivityRoute(
            id: activity.stableID,
            mountedActivity: fetchDetail ? nil : activity
        )) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: activity.lifecycle?.isTerminal == true ? "checkmark.circle" : "circle.dotted")
                    .foregroundStyle(activity.status == .failed ? Color.tronError : accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.title).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).lineLimit(1)
                    Text(activitySummary(activity)).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).lineLimit(2)
                    if let currentTool = activity.currentTool {
                        Label(currentTool, systemImage: "wrench.and.screwdriver").font(TronTypography.caption).foregroundStyle(accent).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
            }
            .padding(11).tronGlassSurface(accent: accent, tintOpacity: 0.08, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.title), \(activitySummary(activity))")
    }

    @ViewBuilder private func groupSection(_ group: ExtensionWidgetGroup) -> some View {
        // Structured lifecycle rows never suppress semantic status, service,
        // or widget content; the hub is one composable native surface.
        if !group.statuses.isEmpty { statusSection(group.statuses) }
        if !group.activities.isEmpty { activitySection(group.activities) }
        if !group.services.isEmpty { serviceSection(group.services) }
        if !group.items.isEmpty {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(group.items) { item in
                    switch item.content {
                    case .semantic(let widget):
                        ExtensionWidgetView(widget: widget, isExpanded: isExpanded) { toggleExpanded() }
                    case .surface(let surface):
                        ExtensionSurfaceWidgetView(surface: surface, isExpanded: isExpanded) { toggleExpanded() }
                    }
                }
            }
        }
        if group.activities.isEmpty && group.statuses.isEmpty && group.services.isEmpty && !hasRenderableItems(group) {
            emptyGroupState
        }
    }

    private func activitySection(_ activities: [ExtensionRunActivity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runs")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(Color.tronTextPrimary)
            Text("Select a run for its structured detail.")
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
            ForEach(ChatExtensionWidgetPolicy.orderedActivities(activities)) { activity in
                NavigationLink(value: ExtensionActivityRoute(
                    id: activity.stableID,
                    mountedActivity: activity
                )) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: activity.isLive ? "circle.dotted" : (activity.status == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle"))
                                .foregroundStyle(activity.status == .failed ? Color.tronError : Color.tronEmerald)
                            Text(activity.title)
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(activity.displayStateName)
                                .font(TronTypography.caption)
                                .foregroundStyle(activity.lifecycle?.state == .failed || activity.status == .failed ? Color.tronError : Color.tronTextMuted)
                        }
                        Text(activitySummary(activity))
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let currentTool = activity.currentTool {
                            Label(currentTool, systemImage: "wrench.and.screwdriver")
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronEmerald)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.1, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(activity.title), \(activitySummary(activity))")
            }
        }
    }

    private var emptyGroupState: some View {
        ContentUnavailableView(
            "No readable extension detail",
            systemImage: "rectangle.dashed",
            description: Text("The extension has not published a displayable live surface.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private func hasRenderableItems(_ group: ExtensionWidgetGroup) -> Bool {
        group.items.contains { item in
            switch item.content {
            case .semantic(let widget):
                return widget.lines.map(NativeExtensionText.clean).contains { !$0.isEmpty }
            case .surface(let surface):
                return surface.frame.plainText.split(separator: "\n").map(String.init).map(NativeExtensionText.clean).contains { !$0.isEmpty }
            }
        }
    }

    private func activitySummary(_ activity: ExtensionRunActivity) -> String {
        let state = activity.displayStateName
        let metrics = [
            activity.currentTool.map { "\($0)" },
            activity.toolCount.map { "\($0) tools" },
            activity.turnCount.map { "\($0) turns" },
            activity.durationMs.map { durationLabel($0) },
        ].compactMap { $0 }
        return ([state] + metrics).joined(separator: " · ")
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func statusSection(_ statuses: [ExtensionActivityStatus]) -> some View {
        TronSettingsGroup("Status", detail: "Live information published by the extension.", accent: .tronEmerald) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(statuses) { status in
                    HStack(alignment: .top, spacing: TronSpacing.sm) {
                        Text(status.displayKey).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).frame(minWidth: 70, alignment: .leading)
                        Text(status.value).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8).accessibilityElement(children: .combine).accessibilityLabel("\(status.key): \(status.value)")
                }
            }
        }
    }

    private func serviceSection(_ services: [ExtensionActivityServiceItem]) -> some View {
        TronSettingsGroup("Extension activity", detail: "Service work remains grouped outside the conversation.", accent: .tronTeal) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(services) { service in
                    HStack(spacing: 10) {
                        Image(systemName: service.error ? "exclamationmark.triangle.fill" : (service.status == "Running" ? "circle.dotted" : "checkmark.circle")).foregroundStyle(service.error ? Color.tronError : Color.tronTeal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.title).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).lineLimit(1)
                            Text("\(service.status) · \(service.source)").font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
                        }
                        Spacer(minLength: 0)
                    }.accessibilityElement(children: .combine).accessibilityLabel("\(service.title), \(service.status)")
                }
            }
        }
    }

    private var settledState: some View {
        VStack(spacing: TronSpacing.sm) {
            Image(systemName: "sparkles").font(TronTypography.sans(size: 30, weight: .medium)).foregroundStyle(Color.tronTextMuted)
            Text("No extension details").font(TronTypography.sans(size: 22, weight: .semibold)).foregroundStyle(Color.tronTextPrimary)
            Text("This extension activity has settled or is no longer mounted.").font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 42).accessibilityElement(children: .combine)
    }

    private func toggleExpanded() {
        guard let presentation else { return }
        let next = !presentation.semanticState.toolsExpanded
        Task {
            do {
                try await model.setExtensionToolsExpanded(sessionID: sessionID, hostEpoch: presentation.hostEpoch, presentationRevision: presentation.revision, expanded: next)
            } catch let failure as GatewayFailure
                where failure.message.localizedCaseInsensitiveContains("presentation epoch is stale")
                    || failure.message.localizedCaseInsensitiveContains("presentation revision is stale") {
                // A newer authoritative presentation already owns the control.
                // The next live snapshot supplies the converged state.
            } catch {
                model.presentConfigurationActionError(error)
            }
        }
    }
}

struct ExtensionRunDetailsSheet: View {
    let sessionID: String
    let activityID: String
    let activityOverride: ExtensionRunActivity?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var durationAnchors: [String: ExtensionActivityDurationAnchor] = [:]

    init(sessionID: String, activityID: String, activityOverride: ExtensionRunActivity? = nil) {
        self.sessionID = sessionID
        self.activityID = activityID
        self.activityOverride = activityOverride
    }

    static func resolveActivity(
        activityID: String,
        extensionActivities: [ExtensionRunActivity],
        toolExecutions: [ToolExecutionState]
    ) -> ExtensionRunActivity? {
        let allActivities = extensionActivities + toolExecutions.compactMap(\.extensionActivity)
        // Routes are created with activity.id. Canonical identity always wins,
        // even when an older projection also exposes a matching alias.
        if let canonical = allActivities.first(where: { $0.stableID == activityID || $0.id == activityID }) { return canonical }

        let legacySyntheticID = activityID.hasPrefix("subagent:") ? activityID : nil
        let aliases = allActivities.filter { activity in
            activity.toolCallId == activityID
                || activity.runId == activityID
                || (legacySyntheticID != nil && activity.runId == String(activityID.dropFirst("subagent:".count)))
        }
        // Compatibility aliases are not ownership proof. Two distinct Gateway
        // records sharing a runId must fail closed rather than pick an arbitrary
        // activity (including one chosen by array order).
        var uniqueByID: [String: ExtensionRunActivity] = [:]
        for activity in aliases { uniqueByID[activity.id] = activity }
        guard uniqueByID.count == 1 else { return nil }
        return uniqueByID.values.first
    }

    private var activity: ExtensionRunActivity? {
        guard let snapshot = model.authoritativeSnapshot(for: sessionID) else { return nil }
        // A mounted override is only a fast first frame. Revalidate its exact
        // identity against the authoritative owner so a lost mounted owner
        // cannot leave a stale detail route alive.
        if let activityOverride {
            // Mounted routes are owned by the mounted activity projection, not
            // by a parallel tool-execution alias. Once that owner disappears,
            // invalidate the route instead of showing a stale live card.
            guard let authoritative = (snapshot.extensionActivities ?? []).first(where: {
                $0.stableID == activityID && $0.stableID == activityOverride.stableID
            }) else { return nil }
            return authoritative
        }
        return Self.resolveActivity(
            activityID: activityID,
            extensionActivities: snapshot.extensionActivities ?? [],
            toolExecutions: snapshot.toolExecutions
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
                if let activity {
                    LazyVStack(alignment: .leading, spacing: TronSpacing.lg) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            summaryCard(activity: activity)
                        }
                        if !activity.children.isEmpty { childSection(activity) }
                        if activity.children.isEmpty && activity.output == nil && activity.currentTool == nil {
                            noStructuredProgressState(activity)
                        }
                        if let output = activity.output, !output.isEmpty {
                            TronSettingsGroup("Recent output", detail: "A bounded live tail from the extension run.", accent: .tronCyan) {
                                Text(output)
                                    .font(TronTypography.codeContent)
                                    .foregroundStyle(Color.tronTextPrimary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, TronSpacing.section)
                    .padding(.top, TronSpacing.md).padding(.bottom, TronSpacing.xl)
                    .task(id: "\(activity.stableID)|\(activity.startedAt)") {
                        if durationAnchors[activity.stableID] == nil {
                            durationAnchors[activity.stableID] = ExtensionActivityDurationAnchor(
                                startedAt: activity.startedAt,
                                observedDurationMs: activity.durationMs ?? 0
                            )
                        }
                    }
                    .onChange(of: activity.durationMs) { _, authoritativeDuration in
                        guard let authoritativeDuration else { return }
                        let current = durationAnchors[activity.stableID]
                        durationAnchors[activity.stableID] = ExtensionActivityDurationAnchor(
                            startedAt: activity.startedAt,
                            observedDurationMs: max(authoritativeDuration, current?.observedDurationMs ?? 0)
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "Activity No Longer Available",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("The Gateway no longer has this bounded live projection.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                }
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { TronSheetTitle(title: activity?.title ?? "Extension run", accent: .tronEmerald) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.foregroundStyle(Color.tronEmerald)
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .accessibilityIdentifier("extension-run-details-sheet")
    }

    private func summaryCard(activity: ExtensionRunActivity) -> some View {
        let state = activity.displayStateName
        let metrics = [
            (state, "Status"),
            (activity.toolCount.map(String.init) ?? "—", "Tools"),
            (activity.turnCount.map(String.init) ?? "—", "Turns"),
            (durationLabel(activeDurationMs(activity)), "Active time"),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text(activity.mode?.capitalized ?? "Extension run")
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 12) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                    VStack(spacing: 3) {
                        Text(metric.0)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                            .foregroundStyle(Color.tronTextPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(metric.1)
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if activity.lifecycle?.attention == .needsAttention {
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronError)
                    .accessibilityLabel("Needs attention")
            }
            if let currentTool = activity.currentTool {
                Label(currentTool, systemImage: "wrench.and.screwdriver")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronEmerald)
            }
        }
        .padding(14)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.14)
    }

    private func activeDurationMs(_ activity: ExtensionRunActivity) -> Int {
        guard activity.isLive else { return activity.durationMs ?? 0 }
        let anchor = durationAnchors[activity.stableID] ?? ExtensionActivityDurationAnchor(
            startedAt: activity.startedAt,
            observedDurationMs: activity.durationMs ?? 0
        )
        return anchor.durationMs()
    }

    private func noStructuredProgressState(_ activity: ExtensionRunActivity) -> some View {
        TronSettingsGroup("Run details", detail: "The run is tracked, but its producer has not published structured progress.", accent: .tronTeal) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Status: \(activity.displayStateName)")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                if let runID = activity.runId {
                    Text("Run ID: \(runID)")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                        .textSelection(.enabled)
                }
                Text("Live output will appear here when available.")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
            }
        }
    }

    private func childSection(_ activity: ExtensionRunActivity) -> some View {
        TronSettingsGroup("Subagents", detail: "Each child keeps its own stable progress identity.", accent: .tronTeal) {
            VStack(spacing: 0) {
                ForEach(activity.children) { child in
                    NavigationLink {
                        SubagentSessionChatView(child: child)
                    } label: {
                        HStack(spacing: 8) {
                            ExtensionChildDisclosureView(child: child, depth: 0)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the live subagent session view")
                    if child.id != activity.children.last?.id { TronSettingsDivider(accent: .tronTeal) }
                }
            }
        }
    }

    private func childSummary(_ child: ExtensionRunChild) -> String {
        let status = child.displayStateName
        let detail = [
            child.currentTool,
            child.toolCount.map { "\($0) tools" },
            child.turnCount.map { "\($0) turns" },
            child.durationMs.map(durationLabel),
        ].compactMap { $0 }
        return ([status] + detail).joined(separator: " · ")
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct SubagentSessionChatView: View {
    let child: ExtensionRunChild

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: TronSpacing.md) {
                statusHeader
                if let task = child.task, !task.isEmpty {
                    chatBubble(role: "Task", text: task, accent: .tronEmerald, trailing: true)
                }
                if let currentTool = child.currentTool, !currentTool.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(child.lifecycle?.isTerminal == true ? "Last tool" : "Working", systemImage: "wrench.and.screwdriver")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                        Text(currentTool)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(Color.tronTextPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .tronGlassSurface(accent: .tronTeal, tintOpacity: 0.12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let output = child.output, !output.isEmpty {
                    chatBubble(role: "Subagent", text: output, accent: .tronCyan, trailing: false)
                } else if child.lifecycle?.isTerminal != true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Color.tronEmerald)
                        Text("Waiting for live subagent output…")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .padding(12)
                    .tronGlassSurface(accent: .tronTeal, tintOpacity: 0.10)
                } else {
                    ContentUnavailableView(
                        "No Output Published",
                        systemImage: "text.bubble",
                        description: Text("The completed subagent did not publish readable output.")
                    )
                }
                if let children = child.children, !children.isEmpty {
                    ForEach(children) { nested in
                        NavigationLink {
                            SubagentSessionChatView(child: nested)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(nested.label).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
                                    Text(nested.displayStateName).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Color.tronTextMuted)
                            }
                            .padding(12)
                            .tronGlassSurface(accent: .tronTeal, tintOpacity: 0.10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, TronSpacing.section)
            .padding(.vertical, TronSpacing.md)
        }
        .tronScrollEdgeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { TronSheetTitle(title: child.label, accent: .tronEmerald) } }
        .accessibilityIdentifier("subagent-session-chat-view")
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: child.lifecycle?.isTerminal == true ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(child.lifecycle == .failed || child.status == .failed ? Color.tronError : Color.tronEmerald)
            VStack(alignment: .leading, spacing: 2) {
                Text(child.displayStateName).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
                let metrics = [child.toolCount.map { "\($0) tools" }, child.turnCount.map { "\($0) turns" }].compactMap { $0 }
                if !metrics.isEmpty {
                    Text(metrics.joined(separator: " · ")).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.12)
    }

    private func chatBubble(role: String, text: String, accent: Color, trailing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(role).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
            Text(text)
                .font(TronTypography.body)
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: accent, tintOpacity: 0.12)
        .padding(trailing ? .leading : .trailing, 28)
    }
}

private struct ExtensionChildDisclosureView: View {
    let child: ExtensionRunChild
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tone)
                VStack(alignment: .leading, spacing: 3) {
                    Text(child.label)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(summary)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let task = child.task, !task.isEmpty {
                        Text(task)
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let output = child.output, !output.isEmpty {
                        Text(output)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(child.label), \(summary)")

            if depth < ExtensionActivityAdmissionPolicy.maximumDepth,
               let children = child.children {
                ForEach(children) { nested in
                    ExtensionChildDisclosureView(child: nested, depth: depth + 1)
                }
            }
        }
    }

    private var symbol: String {
        if child.attention == .needsAttention || child.lifecycle == .failed || child.status == .failed { return "exclamationmark.triangle.fill" }
        if child.lifecycle == .paused { return "pause.circle" }
        return child.lifecycle?.isTerminal == true ? "checkmark.circle" : "circle.dotted"
    }

    private var tone: Color {
        if child.attention == .needsAttention || child.lifecycle == .failed || child.status == .failed { return .tronError }
        return child.lifecycle == .paused ? .tronAmber : .tronTeal
    }

    private var summary: String {
        let state = child.attention == .needsAttention ? "Needs attention" : child.displayStateName
        let metrics = [child.currentTool, child.toolCount.map { "\($0) tools" }, child.turnCount.map { "\($0) turns" }, child.durationMs.map(durationLabel)].compactMap { $0 }
        return ([state] + metrics).joined(separator: " · ")
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

// Retained for diagnostic callers.
struct ExtensionWidgetStackView: View {
    let items: [ChatExtensionWidgetItem]
    var body: some View {
        if !items.isEmpty {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) { ForEach(items) { item in
                    switch item.content { case .semantic(let widget): ExtensionWidgetView(widget: widget); case .surface(let surface): ExtensionSurfaceWidgetView(surface: surface) }
                }}.padding(.vertical, 2)
            }.frame(maxHeight: ChatExtensionWidgetPolicy.maximumStackHeight)
        }
    }
}

struct ExtensionWidgetView: View {
    let widget: ExtensionWidget
    var isExpanded = false
    var onToggleExpanded: (() -> Void)? = nil

    private var lines: [String] { widget.lines.map(NativeExtensionText.clean).filter { !$0.isEmpty } }
    private var hasDetail: Bool { widget.lines.contains { NativeExtensionText.isDetailHint($0) } }
    private var visibleLines: [String] { isExpanded ? lines : Array(lines.prefix(1)) }

    var body: some View {
        Group {
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Spacer()
                        if (hasDetail || isExpanded), let onToggleExpanded {
                            Button(action: onToggleExpanded) {
                                Label(isExpanded ? "Hide detail" : "Show detail", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(TronTypography.caption).foregroundStyle(Color.tronEmerald)
                            }.buttonStyle(.plain)
                        }
                    }
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        nativeRow(line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("extension-widget-\(widget.key)")
    }

    private func nativeRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill").font(TronTypography.sans(size: 5)).foregroundStyle(Color.tronCyan).padding(.top, 7)
            Text(line).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct ExtensionSurfaceWidgetView: View {
    let surface: ExtensionSurface
    var isExpanded = false
    var onToggleExpanded: (() -> Void)? = nil
    private var meaningfulLines: [String] {
        surface.frame.plainText.split(separator: "\n").map(String.init).map(NativeExtensionText.clean).filter { !$0.isEmpty }
    }
    private var hasDetail: Bool { surface.frame.plainText.split(separator: "\n").contains { NativeExtensionText.isDetailHint(String($0)) } }
    var body: some View {
        Group {
            if !meaningfulLines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        if (hasDetail || isExpanded), let onToggleExpanded {
                            Button(action: onToggleExpanded) { Label(isExpanded ? "Hide detail" : "Show detail", systemImage: isExpanded ? "chevron.up" : "chevron.down").font(TronTypography.caption) }.buttonStyle(.plain)
                        }
                    }
                    if isExpanded {
                        ExtensionFrameView(frame: surface.frame)
                    } else {
                        Text(meaningfulLines[0]).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 7)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extension-surface-widget-\(surface.id)")
    }
}

enum NativeExtensionText {
    private static let navigationGlyphs = "↓←→↑↔⇣⇡⇠⇢"

    /// Recognizes complete terminal navigation affordance lines only. Content
    /// that merely mentions an arrow or keyboard remains meaningful content.
    static func isDetailHint(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.range(of: #"^press\b[^\n]*\blive\s+detail\b\s*[.!…]*$"#, options: .regularExpression.union(.caseInsensitive)) != nil {
            return true
        }
        guard text.range(of: #"\bto\s+inspect\b"#, options: .regularExpression.union(.caseInsensitive)) != nil else { return false }
        return text.unicodeScalars.contains { navigationGlyphs.unicodeScalars.contains($0) }
    }

    static func clean(_ raw: String) -> String {
        guard !isDetailHint(raw) else { return "" }
        return raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" { return url.host == nil ? nil : url }
        return url
    }
}
