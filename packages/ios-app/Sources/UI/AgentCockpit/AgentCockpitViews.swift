import SwiftUI

struct AgentCockpitSheet: View {
    @Bindable var viewModel: AgentCockpitViewModel
    let repository: any WorkerLifecycleRepository
    let sessionId: String?
    let workspaceId: String?
    let connectionState: ConnectionState

    @State private var selectedTab: AgentCockpitTab = .workers

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
                    SheetTitle(title: "Runtime Cockpit", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronEmerald,
                        isBusy: viewModel.isRefreshing,
                        accessibilityLabel: "Refresh runtime cockpit"
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
                    Text(viewModel.overview.status.detail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
            }
            if let error = viewModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronError)
            }
            MetricStrip(overview: viewModel.overview)
        }
        .padding(14)
        .sectionFill(.tronEmerald, cornerRadius: 12, interactive: false)
    }

    private var tabPicker: some View {
        TronSegmentedControl(
            options: AgentCockpitTab.allCases.map { (label: $0.title, value: $0) },
            selection: $selectedTab,
            accent: .tronEmerald
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
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
            if viewModel.overview.activity.isEmpty {
                CockpitEmptyState(symbol: "clock", title: "No activity", detail: "Catalog and lifecycle changes will appear here.")
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
        await viewModel.refresh(repository: repository, connectionState: connectionState)
    }
}

private enum AgentCockpitTab: String, CaseIterable, Identifiable {
    case workers
    case packages
    case activity
    case surfaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workers: return "Workers"
        case .packages: return "Packages"
        case .activity: return "Activity"
        case .surfaces: return "Surfaces"
        }
    }

    var systemImage: String {
        switch self {
        case .workers: return "cpu"
        case .packages: return "shippingbox"
        case .activity: return "clock"
        case .surfaces: return "rectangle.3.group"
        }
    }
}

private struct MetricStrip: View {
    let overview: AgentCockpitOverview

    var body: some View {
        HStack(spacing: 8) {
            metric("Workers", value: overview.workers.count, icon: "cpu")
            metric("Functions", value: overview.functions.count, icon: "curlybraces")
            metric("Triggers", value: overview.triggers.count, icon: "bolt")
            metric("Packages", value: overview.packages.count, icon: "shippingbox")
        }
    }

    private func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .sectionFill(.tronEmerald, cornerRadius: 8, subtle: true, interactive: false)
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.systemImage)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(item.detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)
                if let timestamp = item.timestamp {
                    Text(timestamp)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
            }
            Spacer()
        }
        .padding(11)
        .sectionFill(.tronEmerald, cornerRadius: 10, subtle: true, interactive: false)
    }
}

private struct WrapRow: View {
    let items: [String]
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(4), id: \.self) { item in
                Text(item)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.tint(tint.opacity(0.16)), in: .capsule)
            }
        }
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
