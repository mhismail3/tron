import Foundation
import Testing
@testable import TronMobile

private typealias Fixtures = AgentCockpitStateTestFixtures

@Suite("Agent Cockpit State Tests")
struct AgentCockpitStateTests {
    @Test("Projection derives workers functions packages activity and approval status")
    func projectionDerivesCockpitOverview() {
        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(),
            resources: [
                Fixtures.sampleResource(
                    id: "worker_package_proposal:local.echo:1.0.0:invocation-1",
                    kind: .proposal,
                    lifecycle: "proposed"
                )
            ],
            discoveryReports: [
                Fixtures.sampleResource(
                    id: "catalog_discovery_report:2:invocation-2",
                    kind: .catalogDiscoveryReport,
                    lifecycle: "passed"
                )
            ],
            connectionState: .connected
        )

        #expect(overview.status.kind == .awaitingApproval)
        #expect(overview.workers.first?.id == "local.echo")
        #expect(overview.workers.first?.functionCount == 1)
        #expect(overview.functions.first?.id == "local.echo::reply")
        #expect(overview.functions.first?.requestSchemaJSON?.contains(#""type" : "object""#) == true)
        #expect(overview.functions.first?.responseSchemaJSON?.contains(#""type" : "object""#) == true)
        #expect(overview.triggers.first?.targetFunction == "local.echo::reply")
        #expect(overview.packages.first?.packageId == "local.echo")
        #expect(overview.discovery.title == "Verified")
        #expect(overview.discovery.families.first?.id == "local.echo")
        #expect(overview.discovery.groups.isEmpty)
        #expect(overview.discovery.engineGroups.first?.title == "Other Capabilities")
        #expect(overview.discovery.engineGroups.first?.functionCount == 1)
        #expect(overview.discovery.agentOperationCount == 0)
        #expect(overview.discovery.engineFunctionCount == 1)
        #expect(overview.discovery.reports.first?.lifecycle == "passed")
        #expect(overview.activity.isEmpty)
        let summary = AgentCockpitPresentation.dashboardSummary(for: overview)
        #expect(summary.agentActions.value == nil)
        #expect(summary.engineActions.value == nil)
        #expect(summary.engineInterfaces == 1)
    }

    @Test("Projection renders server-owned module activity from resource facts")
    func projectionRendersServerOwnedModuleActivity() {
        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(),
            resources: [
                Fixtures.sampleResource(
                    id: "worker_package_proposal:local.echo:1.0.0:invocation-1",
                    kind: .proposal,
                    lifecycle: "proposed"
                )
            ],
            moduleActivity: Fixtures.sampleModuleActivityOverview(),
            connectionState: .connected
        )

        #expect(overview.activity.count == 1)
        #expect(overview.activity.first?.title == "Runtime envelope")
        #expect(overview.activity.first?.status == "active")
        #expect(overview.activity.first?.resourceKind == "module_runtime_state")
        #expect(overview.activity.first?.authorityLabels.contains("grant redacted") == true)
        #expect(overview.activity.first?.touchedResources.first?.label == "output refs")
        #expect(overview.moduleActivity?.projection.rawPayloadsReturned == false)
        let summary = AgentCockpitPresentation.dashboardSummary(for: overview)
        #expect(summary.statusKind == .awaitingApproval)
        #expect(summary.title == "Needs You")
        #expect(summary.recentActivityTitle == "Active")
        #expect(summary.activeActivity == 1)
    }

    @Test("Projection preserves degraded module activity state")
    func projectionPreservesDegradedModuleActivityState() {
        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(),
            resources: [],
            moduleActivity: Fixtures.sampleDegradedModuleActivityOverview(),
            connectionState: .connected
        )

        #expect(overview.activity.count == 1)
        #expect(overview.activity.first?.status == "degraded")
        #expect(overview.activity.first?.systemImage == "exclamationmark.triangle")
        #expect(overview.moduleActivity?.summary.degraded == 1)
        let summary = AgentCockpitPresentation.dashboardSummary(for: overview)
        #expect(summary.statusKind == .degraded)
        #expect(summary.recentActivityTitle == "Needs review")
        #expect(summary.degradedActivity == 1)
    }

    @Test("Projection marks degraded worker/function health")
    func projectionMarksDegradedHealth() {
        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(functionHealth: "Unhealthy"),
            resources: [],
            connectionState: .connected
        )

        #expect(overview.status.kind == .degraded)
        #expect(overview.status.title == "Degraded")
    }

    @Test("Projection reports offline without calling lifecycle data")
    func projectionReportsOffline() {
        let overview = AgentCockpitOverview.empty(connectionState: .disconnected)

        #expect(overview.status.kind == .offline)
        #expect(overview.status.title == "Offline")
        #expect(overview.workers.isEmpty)
    }

    @Test("Package actions require confirmation and disable unsafe lifecycle states")
    func packageActionsRequireConfirmation() {
        let proposal = Fixtures.samplePackageRow(kind: .proposal, lifecycle: "proposed")
        let installed = Fixtures.samplePackageRow(kind: .installation, lifecycle: "installed")
        let launched = Fixtures.samplePackageRow(kind: .launchAttempt, lifecycle: "launched")

        let proposalActions = AgentCockpitProjection.actions(for: proposal)
        let installedActions = AgentCockpitProjection.actions(for: installed)
        let launchActions = AgentCockpitProjection.actions(for: launched)

        #expect(proposalActions.first?.kind == .installProposal)
        #expect(proposalActions.first?.isEnabled == true)
        #expect(AgentCockpitProjection.confirmation(for: proposalActions[0]).message.contains("validate the manifest"))
        #expect(installedActions.first { $0.kind == .enablePackage }?.isEnabled == true)
        #expect(installedActions.first { $0.kind == .launchWorker }?.isEnabled == false)
        #expect(launchActions.first?.kind == .stopWorker)
        #expect(launchActions.first?.isDestructive == true)
    }

}
