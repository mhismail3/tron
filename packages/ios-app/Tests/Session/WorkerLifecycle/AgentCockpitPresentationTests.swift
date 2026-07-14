import Foundation
import Testing
@testable import TronMobile

private typealias Fixtures = AgentCockpitStateTestFixtures

@Suite("Agent Cockpit Presentation Tests")
struct AgentCockpitPresentationTests {
    @Test("Dashboard prioritizes waiting work over routine active work")
    func dashboardPrioritizesWaitingWork() {
        var activity = Fixtures.sampleModuleActivityOverview()
        activity.summary.total = 2
        activity.summary.waiting = 1
        activity.summary.detail = "One item needs your review while work continues."
        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(),
            resources: [],
            moduleActivity: activity,
            connectionState: .connected
        )

        let summary = AgentCockpitPresentation.dashboardSummary(for: overview)
        #expect(summary.statusKind == .awaitingApproval)
        #expect(summary.title == "Needs You")
        #expect(summary.recentActivityTitle == "Needs you")
        #expect(summary.activeActivity == 1)
        #expect(summary.waitingActivity == 1)
    }

    @Test("Dashboard quiet state is concise and does not repeat Idle")
    func dashboardQuietStateIsConcise() {
        let summary = AgentCockpitPresentation.dashboardSummary(
            for: .empty(connectionState: .connected)
        )

        #expect(summary.title == "All Systems Quiet")
        #expect(summary.recentActivityTitle == "No recent work")
        #expect(summary.agentActions.value == nil)
        #expect(summary.engineActions.value == nil)
        #expect(
            AgentCockpitPresentation.verificationDetail(for: .empty)
                == "Agent action inventory is unavailable."
        )
    }

    @Test("Dashboard groups activity by server-owned state without duplicating items")
    func dashboardGroupsActivityByServerOwnedState() {
        func item(_ id: String, status: String) -> AgentCockpitActivityItem {
            AgentCockpitActivityItem(
                id: id,
                title: id,
                detail: "Server-owned activity",
                timestamp: nil,
                systemImage: "clock",
                status: status,
                resourceKind: "module_runtime_state",
                authorityLabels: [],
                touchedResources: [],
                rollbackStatus: nil,
                quarantineStatus: nil,
                runtimeAuthorizationStatus: nil
            )
        }

        let items = [
            item("recorded", status: "recorded"),
            item("active", status: "running"),
            item("waiting", status: "waiting"),
            item("blocked", status: "blocked"),
            item("degraded", status: "failed")
        ]
        let sections = AgentCockpitPresentation.activitySections(from: items)

        #expect(sections.map(\.kind) == [.needsReview, .needsYou, .activeWork, .recentActivity])
        #expect(sections[0].items.map(\.id) == ["blocked", "degraded"])
        #expect(sections[1].items.map(\.id) == ["waiting"])
        #expect(sections[2].items.map(\.id) == ["active"])
        #expect(sections[3].items.map(\.id) == ["recorded"])
        let presentedIDs = sections.flatMap(\.items).map(\.id)
        #expect(presentedIDs.count == items.count)
        #expect(Set(presentedIDs) == Set(items.map(\.id)))
    }

    @Test("Bounded capability projection labels action counts as lower bounds")
    func boundedCapabilityProjectionLabelsActionCountsAsLowerBounds() {
        var visibility = AgentCockpitViewModelTests.capabilityCockpitOverview()
        visibility.operationList.complete = false
        visibility.operationList.truncated = true

        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(),
            resources: [],
            capabilityVisibility: visibility,
            connectionState: .connected
        )
        let summary = AgentCockpitPresentation.dashboardSummary(for: overview)

        #expect(!summary.agentActions.isComplete)
        #expect(summary.agentActions.displayValue == "1+")
        #expect(!summary.engineActions.isComplete)
        #expect(summary.engineActions.displayValue == "1+")
    }

    @Test("Cockpit presentation keeps top-level labels user-facing")
    func cockpitPresentationKeepsTopLevelLabelsUserFacing() {
        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(),
            resources: [],
            discoveryReports: [
                Fixtures.sampleResource(
                    id: "catalog_discovery_report:2:invocation-2",
                    kind: .catalogDiscoveryReport,
                    lifecycle: "passed"
                )
            ],
            capabilityVisibility: AgentCockpitViewModelTests.capabilityCockpitOverview(),
            moduleActivity: Fixtures.sampleModuleActivityOverview(),
            connectionState: .connected
        )

        let dashboardSummary = AgentCockpitPresentation.dashboardSummary(for: overview)
        let topLevelStrings = [
            dashboardSummary.title,
            dashboardSummary.detail,
            dashboardSummary.agentActions.phrase(
                singular: "agent action",
                plural: "agent actions"
            ),
            dashboardSummary.engineActions.phrase(
                singular: "engine action",
                plural: "engine actions"
            ),
            dashboardSummary.recentActivityTitle,
            AgentCockpitPresentation.verificationDetail(for: overview.discovery),
            dashboardSummary.verification,
            AgentCockpitPresentation.verificationStatus(for: overview.discovery.latestReport),
            AgentCockpitPresentation.workKindLabel(overview.moduleActivity?.resources.first?.kind ?? ""),
            AgentCockpitPresentation.workStateLine(
                kind: overview.activity.first?.resourceKind ?? "",
                status: overview.activity.first?.status ?? ""
            )
        ]

        #expect(AgentCockpitPresentation.hiddenTopLevelTerms(in: topLevelStrings).isEmpty)
        #expect(topLevelStrings.contains("Active"))
        #expect(topLevelStrings.contains("Verified"))
        #expect(topLevelStrings.contains("Runtime"))
        #expect(AgentCockpitPresentation.functionDisplayName("agent::abort_invocation") == "Abort Invocation Agent")
        #expect(AgentCockpitPresentation.capabilityReplacementClassLabel("runtime_routable") == "Can be replaced safely")
        #expect(AgentCockpitPresentation.capabilityVisibilityLabel("default_visible") == "Visible to the agent")
        #expect(AgentCockpitPresentation.capabilityMinimalityLabel("module_candidate") == "Can become a module")
        #expect(AgentCockpitPresentation.provenanceLabel("capability binding cockpit projection") == "Dashboard projection")
    }

}
