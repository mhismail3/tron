import Foundation
import Testing
@testable import TronMobile

@Suite("Agent Cockpit State Tests")
struct AgentCockpitStateTests {
    @Test("Projection derives workers functions packages activity and approval status")
    func projectionDerivesCockpitOverview() {
        let overview = AgentCockpitProjection.project(
            snapshot: sampleCatalogSnapshot(),
            resources: [
                sampleResource(
                    id: "worker_package_proposal:local.echo:1.0.0:invocation-1",
                    kind: .proposal,
                    lifecycle: "proposed"
                )
            ],
            discoveryReports: [
                sampleResource(
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
        #expect(overview.triggers.first?.targetFunction == "local.echo::reply")
        #expect(overview.packages.first?.packageId == "local.echo")
        #expect(overview.discovery.title == "Verified")
        #expect(overview.discovery.families.first?.id == "local.echo")
        #expect(overview.discovery.reports.first?.lifecycle == "passed")
        #expect(overview.activity.contains { $0.title.contains("worker package proposal") })
    }

    @Test("Projection marks degraded worker/function health")
    func projectionMarksDegradedHealth() {
        let overview = AgentCockpitProjection.project(
            snapshot: sampleCatalogSnapshot(functionHealth: "Unhealthy"),
            resources: [],
            connectionState: .connected
        )

        #expect(overview.status.kind == .degraded)
        #expect(overview.status.title == "Degraded")
    }

    @Test("Projection marks missing schema evidence")
    func projectionMarksMissingSchemaEvidence() {
        let snapshot = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "local.echo::reply",
                        "owner_worker": "local.echo",
                        "description": "Reply from local echo",
                        "visibility": "Agent",
                        "effect_class": "PureRead",
                        "risk_level": "Low",
                        "health": "Healthy",
                        "tags": ["echo"]
                    ])
                ],
                workers: [],
                triggers: [],
                triggerTypes: []
            ),
            currentRevision: 2,
            nextRevision: 3,
            hasMore: false
        )

        let overview = AgentCockpitProjection.project(
            snapshot: snapshot,
            resources: [],
            connectionState: .connected
        )

        #expect(overview.status.kind == .degraded)
        #expect(overview.discovery.title == "Schema Gaps")
        #expect(overview.discovery.missingSchemaCount == 1)
        #expect(overview.discovery.families.first?.missingSchemaCount == 1)
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
        let proposal = samplePackageRow(kind: .proposal, lifecycle: "proposed")
        let installed = samplePackageRow(kind: .installation, lifecycle: "installed")
        let launched = samplePackageRow(kind: .launchAttempt, lifecycle: "launched")

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

    private func sampleCatalogSnapshot(functionHealth: String = "Healthy") -> CatalogWatchSnapshotDTO {
        CatalogWatchSnapshotDTO(
            changes: [
                CatalogChangeDTO(
                    id: "change-1",
                    beforeRevision: 1,
                    afterRevision: 2,
                    kind: "worker_registered",
                    subjectId: "local.echo",
                    subjectKind: "worker",
                    changeClass: "availability",
                    visibility: "system",
                    sessionId: nil,
                    workspaceId: nil,
                    ownerWorker: "local.echo",
                    timestamp: "2026-06-14T12:00:00Z"
                )
            ],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "local.echo::reply",
                        "owner_worker": "local.echo",
                        "description": "Reply from local echo",
                        "visibility": "Agent",
                        "effect_class": "PureRead",
                        "risk_level": "Low",
                        "health": functionHealth,
                        "tags": ["echo"],
                        "request_schema": ["type": "object"],
                        "response_schema": ["type": "object"]
                    ])
                ],
                workers: [
                    AnyCodable([
                        "id": "local.echo",
                        "kind": "External",
                        "lifecycle": "Ready",
                        "owner_actor": "system",
                        "authority_grant": "engine-transport",
                        "namespace_claims": ["local.echo"],
                        "visibility": "System"
                    ])
                ],
                triggers: [
                    AnyCodable([
                        "id": "local.echo.tick",
                        "owner_worker": "local.echo",
                        "trigger_type": "cron",
                        "target_function": "local.echo::reply",
                        "delivery_mode": "Async",
                        "visibility": "System"
                    ])
                ],
                triggerTypes: [
                    AnyCodable([
                        "id": "cron",
                        "owner_worker": "local.echo",
                        "description": "Cron trigger",
                        "allowed_delivery_modes": ["Async"],
                        "visibility": "System"
                    ])
                ]
            ),
            currentRevision: 2,
            nextRevision: 3,
            hasMore: false
        )
    }

    private func sampleResource(
        id: String,
        kind: WorkerLifecycleResourceKind,
        lifecycle: String
    ) -> EngineResourceDTO {
        EngineResourceDTO(
            resourceId: id,
            kind: kind.rawValue,
            schemaId: nil,
            scope: AnyCodable("system"),
            ownerWorkerId: "worker",
            ownerActorId: "system",
            lifecycle: lifecycle,
            policy: nil,
            currentVersionId: "version-1",
            traceId: nil,
            createdByInvocationId: nil,
            createdAt: nil,
            updatedAt: "2026-06-14T12:00:00Z"
        )
    }

    private func samplePackageRow(
        kind: WorkerLifecycleResourceKind,
        lifecycle: String
    ) -> AgentCockpitPackageRow {
        AgentCockpitPackageRow(
            id: "\(kind.rawValue):local.echo:1.0.0",
            kind: kind,
            packageId: "local.echo",
            packageVersion: "1.0.0",
            lifecycle: lifecycle,
            resourceId: "\(kind.rawValue):local.echo:1.0.0",
            currentVersionId: "version-1",
            updatedAt: nil
        )
    }
}
