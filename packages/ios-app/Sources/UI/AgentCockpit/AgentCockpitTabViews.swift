import SwiftUI

// MARK: - Progressive Cockpit Tabs

extension AgentCockpitSheet {
    var visibleTabs: [AgentCockpitTab] {
        AgentCockpitTab.visibleTabs(for: viewModel.overview)
    }

    @ViewBuilder
    var tabContent: some View {
        switch visibleTabs.contains(selectedTab) ? selectedTab : .capabilities {
        case .capabilities:
            capabilitiesTab
        case .engine:
            engineTab
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
            if !viewModel.overview.routeStories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What Changed")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextSecondary)
                    ForEach(viewModel.overview.routeStories) { story in
                        Button {
                            selectedRouteStory = routeStorySelection(for: story)
                        } label: {
                            RouteStoryCard(story: story)
                        }
                        .buttonStyle(.plain)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .disabled(routeStorySelection(for: story) == nil)
                        .accessibilityIdentifier("route-story-\(story.operation)")
                    }
                }
            }
            if viewModel.overview.discovery.groups.isEmpty {
                CockpitEmptyState(
                    symbol: "questionmark.folder",
                    title: viewModel.overview.capabilityVisibility == nil
                        ? "Action inventory unavailable"
                        : "No capabilities",
                    detail: viewModel.overview.capabilityVisibility == nil
                        ? "The engine did not return an authoritative agent-action projection."
                        : "The connected engine has not published visible capabilities."
                )
            } else {
                ForEach(viewModel.overview.discovery.groups) { group in
                    Button {
                        selectedCapabilityGroup = group
                    } label: {
                        CapabilityGroupCard(group: group, scope: .capabilities)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("capability-group-\(group.id)")
                }
            }
        }
    }

    private var engineTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            EngineCoreSummaryCard(overview: viewModel.overview.discovery)
            if viewModel.overview.discovery.engineGroups.isEmpty {
                CockpitEmptyState(
                    symbol: "lock.shield",
                    title: "No engine interfaces",
                    detail: "The connected engine has not published inspectable kernel or governance interfaces."
                )
            } else {
                ForEach(viewModel.overview.discovery.engineGroups) { group in
                    Button {
                        selectedCapabilityGroup = group
                    } label: {
                        CapabilityGroupCard(group: group, scope: .engine)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("engine-capability-group-\(group.id)")
                }
            }
        }
    }

    private var workersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.overview.workers.isEmpty {
                CockpitEmptyState(
                    symbol: "cpu",
                    title: "No workers",
                    detail: "Autonomous module workers will appear here when they publish runtime owners."
                )
            } else {
                ForEach(viewModel.overview.workers) { worker in
                    WorkerCard(
                        worker: worker,
                        functions: viewModel.overview.functions,
                        triggers: viewModel.overview.triggers
                    )
                }
            }
        }
    }

    private var packagesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.overview.packages.isEmpty {
                CockpitEmptyState(
                    symbol: "shippingbox",
                    title: "No packages",
                    detail: "Module package lifecycle evidence has not been recorded."
                )
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
            CapabilityIssuesCard(overview: viewModel.overview)
            if let moduleActivity = viewModel.overview.moduleActivity {
                ModuleActivitySummaryCard(activity: moduleActivity)
            }
            if viewModel.overview.activity.isEmpty {
                CockpitEmptyState(
                    symbol: "clock",
                    title: "No engine work",
                    detail: "No engine or module work is running, waiting, or blocked."
                )
            } else {
                ForEach(viewModel.overview.activity) { item in
                    ActivityRow(item: item)
                }
            }
            if !viewModel.overview.discovery.reports.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Verification")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextSecondary)
                    ForEach(viewModel.overview.discovery.reports.prefix(4)) { report in
                        CatalogVerificationRow(report: report)
                    }
                }
            }
        }
    }

    private var surfacesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.overview.runtimeSurfaces.isEmpty {
                CockpitEmptyState(
                    symbol: "rectangle.3.group",
                    title: "No surfaces",
                    detail: "Module-authored runtime surfaces will appear here."
                )
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

    private func routeStorySelection(
        for story: AgentCockpitRouteStoryRow
    ) -> AgentCockpitOperationSelection? {
        for group in viewModel.overview.discovery.groups {
            if let operation = group.operations.first(where: { $0.name == story.operation }) {
                return AgentCockpitOperationSelection(operation: operation, group: group)
            }
        }
        return nil
    }
}

enum AgentCockpitTab: String, CaseIterable, Identifiable {
    case capabilities
    case engine
    case workers
    case packages
    case activity
    case surfaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capabilities: return "Capabilities"
        case .engine: return "Engine"
        case .workers: return "Workers"
        case .packages: return "Packages"
        case .activity: return "Activity"
        case .surfaces: return "Surfaces"
        }
    }

    var systemImage: String {
        switch self {
        case .capabilities: return "checkmark.shield"
        case .engine: return "lock.shield"
        case .workers: return "cpu"
        case .packages: return "shippingbox"
        case .activity: return "clock"
        case .surfaces: return "rectangle.3.group"
        }
    }

    static func visibleTabs(for overview: AgentCockpitOverview) -> [Self] {
        var tabs: [Self] = [.capabilities, .engine, .activity]
        if !overview.workers.isEmpty { tabs.append(.workers) }
        if !overview.packages.isEmpty { tabs.append(.packages) }
        if !overview.runtimeSurfaces.isEmpty { tabs.append(.surfaces) }
        return tabs
    }
}
