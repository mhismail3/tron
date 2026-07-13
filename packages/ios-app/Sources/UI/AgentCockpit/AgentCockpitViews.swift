import SwiftUI

struct AgentCockpitSheet: View {
    @Bindable var viewModel: AgentCockpitViewModel
    let repository: any WorkerLifecycleRepository
    let sessionId: String?
    let workspaceId: String?
    let connectionState: ConnectionState

    @State var selectedTab: AgentCockpitTab = .capabilities
    @State var selectedCapabilityGroup: AgentCockpitCapabilityGroupRow?
    @State var selectedRouteStory: AgentCockpitOperationSelection?

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
                    SheetTitle(title: "Dashboard", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronEmerald,
                        isBusy: viewModel.isRefreshing,
                        accessibilityLabel: "Refresh dashboard"
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
        .sheet(item: $selectedRouteStory) { selection in
            CapabilityOperationDetailSheet(
                operation: selection.operation,
                group: selection.group,
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
            AgentCockpitDashboardSummaryCard(overview: viewModel.overview) {
                Task {
                    await viewModel.verifyCatalogDiscovery(
                        repository: repository,
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        connectionState: connectionState
                    )
                }
            }
            if viewModel.lastError != nil {
                Label("Latest refresh could not complete. Low-level diagnostics stay in evidence detail.", systemImage: "exclamationmark.triangle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronError)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronError, cornerRadius: 10, subtle: true, interactive: false)
            }
        }
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

    private func refresh() async {
        await viewModel.refresh(
            repository: repository,
            sessionId: sessionId,
            workspaceId: workspaceId,
            connectionState: connectionState
        )
    }

}

struct AgentCockpitOperationSelection: Identifiable {
    let operation: AgentCockpitOperationRow
    let group: AgentCockpitCapabilityGroupRow

    var id: String { operation.id }
}

struct WorkerCard: View {
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
                WrapRow(items: worker.namespaceClaims.map(AgentCockpitPresentation.displayLabel), tint: .tronInfo)
            }
            ownedRows(title: "Engine interfaces", values: worker.functionIds)
            ownedRows(title: "Triggers", values: worker.triggerIds)
            Text("Server-governed owner · \(AgentCockpitPresentation.displayLabel(worker.ownerActor))")
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

struct PackageCard: View {
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
            Text("Lifecycle evidence is retained by the engine.")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
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

struct ActivityRow: View {
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
                    Text(AgentCockpitPresentation.workStateLine(kind: item.resourceKind, status: item.status))
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

struct CockpitEmptyState: View {
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
