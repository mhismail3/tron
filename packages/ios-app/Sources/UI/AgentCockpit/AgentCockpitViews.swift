import SwiftUI

struct AgentCockpitSheet: View {
    @Bindable var viewModel: AgentCockpitViewModel
    let repository: any WorkerLifecycleRepository
    let sessionId: String?
    let workspaceId: String?
    let connectionState: ConnectionState

    @State private var selectedTab: AgentCockpitTab = .capabilities
    @State private var selectedCapabilityGroup: AgentCockpitCapabilityGroupRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    tabPicker
                    tabContent
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Engine Cockpit", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronEmerald,
                        isBusy: viewModel.isRefreshing,
                        accessibilityLabel: "Refresh engine cockpit"
                    ) {
                        Task { await refresh() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .task {
                await refresh()
            }
            .confirmationDialog(
                viewModel.pendingConfirmation?.title ?? "Confirm",
                isPresented: confirmationPresented,
                titleVisibility: .visible
            ) {
                if let confirmation = viewModel.pendingConfirmation {
                    Button(confirmation.confirmLabel, role: confirmation.action.isDestructive ? .destructive : nil) {
                        Task {
                            await viewModel.performPendingConfirmation(
                                repository: repository,
                                sessionId: sessionId,
                                workspaceId: workspaceId,
                                connectionState: connectionState
                            )
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        viewModel.clearConfirmation()
                    }
                }
            } message: {
                Text(viewModel.pendingConfirmation?.message ?? "")
            }
        }
        .sheet(item: $selectedCapabilityGroup) { group in
            CapabilityGroupDetailSheet(
                group: group,
                latestReport: viewModel.overview.discovery.latestReport
            )
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { viewModel.pendingConfirmation != nil },
            set: { if !$0 { viewModel.clearConfirmation() } }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: viewModel.overview.status.systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.overview.status.title)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(headerDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
            }
            if viewModel.lastError != nil {
                Label("Latest refresh could not complete. Low-level diagnostics stay in audit detail.", systemImage: "exclamationmark.triangle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronError)
            }
            AgentCockpitMetricStrip(overview: viewModel.overview)
        }
        .padding(14)
        .sectionFill(.tronEmerald, cornerRadius: 12, interactive: false)
    }

    private var tabPicker: some View {
        TronSegmentedControl(
            options: visibleTabs.map { (label: $0.title, value: $0) },
            selection: Binding(
                get: { visibleTabs.contains(selectedTab) ? selectedTab : .capabilities },
                set: { selectedTab = $0 }
            ),
            accent: .tronEmerald
        )
    }

    private var headerDetail: String {
        switch viewModel.overview.status.kind {
        case .connecting:
            return "Rebuilding the engine link."
        case .degraded:
            return "Open the cockpit sections for safe diagnostics and audit detail."
        case .awaitingApproval:
            return "A server-owned item is waiting for your review."
        case .running:
            return "Engine or module work is currently active."
        case .ready:
            return "Core link is healthy and capabilities are available."
        case .idle:
            return "No engine or module work is currently active."
        case .offline:
            return "Connect a server to inspect core health."
        }
    }

    private var visibleTabs: [AgentCockpitTab] {
        AgentCockpitTab.visibleTabs(for: viewModel.overview)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch visibleTabs.contains(selectedTab) ? selectedTab : .capabilities {
        case .capabilities:
            capabilitiesTab
        case .workers:
            workersTab
        case .packages:
            packagesTab
        case .activity:
            activityTab
        case .surfaces:
            surfacesTab
        }
    }

    private var capabilitiesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            CapabilitiesSummaryCard(
                overview: viewModel.overview.discovery,
                currentRevision: viewModel.overview.currentRevision
            ) {
                Task {
                    await viewModel.verifyCatalogDiscovery(
                        repository: repository,
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        connectionState: connectionState
                    )
                }
            }
            WorkerTriggerExplanationCard(
                workers: viewModel.overview.workers.count,
                triggers: viewModel.overview.triggers.count,
                operations: viewModel.overview.modularityOperations.isEmpty
                    ? viewModel.overview.functions.count
                    : viewModel.overview.modularityOperations.count
            )
            if viewModel.overview.discovery.groups.isEmpty {
                CockpitEmptyState(symbol: "questionmark.folder", title: "No capabilities", detail: "The connected engine has not published a visible capability catalog.")
            } else {
                ForEach(viewModel.overview.discovery.groups) { group in
                    Button {
                        selectedCapabilityGroup = group
                    } label: {
                        CapabilityGroupCard(group: group)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("capability-group-\(group.id)")
                }
            }
            if !viewModel.overview.discovery.reports.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Verification Proof")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextSecondary)
                    ForEach(viewModel.overview.discovery.reports.prefix(4)) { report in
                        CatalogVerificationRow(report: report)
                    }
                }
            }
        }
    }

    private var workersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.overview.workers.isEmpty {
                CockpitEmptyState(symbol: "cpu", title: "No workers", detail: "The connected engine has not published worker entries.")
            } else {
                ForEach(viewModel.overview.workers) { worker in
                    WorkerCard(worker: worker, functions: viewModel.overview.functions, triggers: viewModel.overview.triggers)
                }
            }
        }
    }

    private var packagesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.overview.packages.isEmpty {
                CockpitEmptyState(symbol: "shippingbox", title: "No packages", detail: "Worker package lifecycle evidence has not been recorded.")
            } else {
                ForEach(viewModel.overview.packages) { package in
                    PackageCard(package: package) { action in
                        viewModel.requestConfirmation(for: action)
                    }
                }
            }
        }
    }

    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let moduleActivity = viewModel.overview.moduleActivity {
                ModuleActivitySummaryCard(activity: moduleActivity)
            }
            if viewModel.overview.activity.isEmpty {
                CockpitEmptyState(symbol: "clock", title: "No engine work", detail: "No engine or module work is running, waiting, or blocked.")
            } else {
                ForEach(viewModel.overview.activity) { item in
                    ActivityRow(item: item)
                }
            }
        }
    }

    private var surfacesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.overview.runtimeSurfaces.isEmpty {
                CockpitEmptyState(symbol: "rectangle.3.group", title: "No surfaces", detail: "Worker-authored runtime surfaces will appear here.")
            } else {
                ForEach(viewModel.overview.runtimeSurfaces) { runtimeSurface in
                    GeneratedRuntimeSurfaceView(
                        surface: runtimeSurface.surface,
                        resourceRef: runtimeSurface.resourceRef,
                        observedVersionId: runtimeSurface.resourceRef.versionId
                    )
                }
            }
        }
    }

    private var statusColor: Color {
        switch viewModel.overview.status.kind {
        case .offline, .connecting:
            return .tronTextMuted
        case .idle, .ready:
            return .tronInfo
        case .running:
            return .tronCyan
        case .awaitingApproval:
            return .tronWarning
        case .degraded:
            return .tronError
        }
    }

    private func refresh() async {
        await viewModel.refresh(
            repository: repository,
            sessionId: sessionId,
            workspaceId: workspaceId,
            connectionState: connectionState
        )
    }
}

private enum AgentCockpitTab: String, CaseIterable, Identifiable {
    case capabilities
    case workers
    case packages
    case activity
    case surfaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capabilities: return "Capabilities"
        case .workers: return "Workers"
        case .packages: return "Packages"
        case .activity: return "Activity"
        case .surfaces: return "Surfaces"
        }
    }

    var systemImage: String {
        switch self {
        case .capabilities: return "checkmark.shield"
        case .workers: return "cpu"
        case .packages: return "shippingbox"
        case .activity: return "clock"
        case .surfaces: return "rectangle.3.group"
        }
    }

    static func visibleTabs(for overview: AgentCockpitOverview) -> [Self] {
        var tabs: [Self] = [.capabilities, .activity]
        if !overview.workers.isEmpty { tabs.append(.workers) }
        if !overview.packages.isEmpty { tabs.append(.packages) }
        if !overview.runtimeSurfaces.isEmpty { tabs.append(.surfaces) }
        return tabs
    }
}

private struct WorkerCard: View {
    let worker: AgentCockpitWorkerRow
    let functions: [AgentCockpitFunctionRow]
    let triggers: [AgentCockpitTriggerRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundStyle(.tronInfo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(worker.id)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(worker.kind) · \(worker.lifecycle) · \(worker.visibility)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                Text("\(worker.functionCount)")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .countBadge(.tronInfo)
            }
            if !worker.namespaceClaims.isEmpty {
                WrapRow(items: worker.namespaceClaims, tint: .tronInfo)
            }
            ownedRows(title: "Functions", values: worker.functionIds)
            ownedRows(title: "Triggers", values: worker.triggerIds)
            Text("Grant \(worker.authorityGrant) · Owner \(worker.ownerActor)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    @ViewBuilder
    private func ownedRows(title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextSecondary)
                ForEach(values.prefix(4), id: \.self) { value in
                    Text(value)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

private struct PackageCard: View {
    let package: AgentCockpitPackageRow
    let onAction: (AgentCockpitAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: package.kind == .proposal ? "checkmark.seal" : "shippingbox")
                    .foregroundStyle(package.kind == .proposal ? .tronWarning : .tronInfo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.displayName)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(package.kind.rawValue.replacingOccurrences(of: "_", with: " ")) · \(package.lifecycle)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
            }
            Text(package.resourceId)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            let actions = AgentCockpitProjection.actions(for: package)
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button {
                            onAction(action)
                        } label: {
                            Text(action.title)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(action.isEnabled ? .tronEmerald : .tronTextDisabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .glassEffect(
                                    .regular.tint(Color.tronEmerald.opacity(0.18)).interactive(action.isEnabled),
                                    in: .capsule
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!action.isEnabled)
                    }
                }
            }
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }
}

private struct ActivityRow: View {
    let item: AgentCockpitActivityItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(item.detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                    Text("\(item.resourceKind.replacingOccurrences(of: "_", with: " ")) · \(item.status)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(statusColor)
                    if let timestamp = item.timestamp {
                        Text(timestamp)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                Spacer()
            }
            if !item.authorityLabels.isEmpty {
                WrapRow(items: item.authorityLabels, tint: .tronInfo)
            }
            if !item.touchedResources.isEmpty {
                WrapRow(
                    items: item.touchedResources.map { "\($0.label) \($0.total)\($0.truncated ? "+" : "")" },
                    tint: .tronCyan
                )
            }
            gateRow
        }
        .padding(11)
        .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: false)
    }

    @ViewBuilder
    private var gateRow: some View {
        let gates = [item.rollbackStatus, item.quarantineStatus, item.runtimeAuthorizationStatus]
            .compactMap { $0 }
            .filter { $0.state != "not_declared" && $0.state != "clear" }
        if !gates.isEmpty {
            HStack(spacing: 6) {
                ForEach(gates, id: \.label) { gate in
                    Label("\(gate.label): \(gate.state)", systemImage: gate.blocked ? "xmark.octagon" : gate.waiting ? "hourglass" : "checkmark.circle")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(gate.blocked ? .tronError : gate.waiting ? .tronWarning : .tronTextSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var statusColor: Color {
        switch AgentCockpitProjection.normalized(item.status) {
        case "blocked": return .tronError
        case "degraded": return .tronWarning
        case "waiting": return .tronWarning
        case "active": return .tronCyan
        case "ready": return .tronInfo
        default: return .tronTextSecondary
        }
    }
}

struct WrapRow: View {
    let items: [String]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items.prefix(4), id: \.self) { item in
                Text(item)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.tint(tint.opacity(0.16)), in: .capsule)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CockpitEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(detail)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }
}
