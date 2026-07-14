import Foundation
import Testing
@testable import TronMobile

private typealias Fixtures = AgentCockpitStateTestFixtures

@Suite("Agent Cockpit Discovery State Tests")
struct AgentCockpitDiscoveryStateTests {
    @Test("Projection renders capability cockpit operation ownership and attempts without raw owner text")
    func projectionRendersCapabilityCockpitVisibility() {
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
            connectionState: .connected
        )

        #expect(overview.discovery.operationCount == 2)
        #expect(overview.modularityOperations.count == 2)
        #expect(overview.discovery.agentOperationCount == 1)
        #expect(overview.discovery.engineOperationCount == 1)
        #expect(overview.discovery.engineFunctionCount == 1)
        let dashboardSummary = AgentCockpitPresentation.dashboardSummary(for: overview)
        #expect(dashboardSummary.agentActions.value == 1)
        #expect(dashboardSummary.agentActions.isComplete)
        #expect(dashboardSummary.workers == 1)
        #expect(dashboardSummary.triggers == 1)
        #expect(dashboardSummary.engineActions.value == 1)
        #expect(dashboardSummary.engineActions.isComplete)
        #expect(dashboardSummary.engineInterfaces == 1)
        #expect(dashboardSummary.verification == "Verified")
        #expect(
            dashboardSummary.agentActions.phrase(
                singular: "agent action",
                plural: "agent actions"
            ) == "1 agent action"
        )
        #expect(
            dashboardSummary.engineActions.phrase(
                singular: "engine action",
                plural: "engine actions"
            ) == "1 engine action"
        )
        #expect(
            AgentCockpitPresentation.countPhrase(
                dashboardSummary.workers,
                singular: "worker",
                plural: "workers"
            ) == "1 worker"
        )
        #expect(
            AgentCockpitDashboardCount(value: 1, isComplete: false).phrase(
                singular: "agent action",
                plural: "agent actions"
            ) == "1+ agent actions"
        )
        let git = overview.modularityOperations.first { $0.name == "git_status" }
        #expect(git?.displayName == "Inspect Git Status")
        #expect(git?.description == "Inspects the current repository state without changing it.")
        #expect(git?.ownerLabel == "Built-in Git adapter")
        #expect(git?.metadataSourceLabel == "Capability execute registry")
        #expect(git?.projectionSourceLabel == "Capability binding cockpit projection")
        #expect(git?.statusKind == "built_in_adapter")
        #expect(git?.capabilitySurface == "agent_operation")
        #expect(git?.capabilityAudience == "session_work")
        #expect(git?.capabilityReplacementClass == "runtime_routable")
        #expect(git?.capabilityDefaultVisibility == "default_visible")
        #expect(git?.capabilityMinimalityDecision == "module_candidate")
        #expect(git?.canReplace == true)
        #expect(git?.replacementTargetLabel == "Governed Git adapter")
        #expect(git?.readinessState == "needs_governance_review")
        #expect(git?.readinessNextActionLabel == "Inspect decisions")
        #expect(git?.failedReplacementAttempts == 1)
        #expect(git?.shadowRuns == 1)
        #expect(git?.routeState == "active")
        #expect(git?.routeLabel == "Active route")
        #expect(git?.activeRoutes == 1)
        #expect(git?.routeEvents == 2)
        #expect(git?.routedInvocations == 1)
        #expect(git?.routeRollbackAvailable == true)
        #expect(git?.routeDisableAvailable == true)
        #expect(git?.rollbackAvailable == true)
        #expect(git?.statusDetail.contains("Family:") == false)
        #expect(git?.ownerLabel.contains("domains::") == false)
        #expect(git?.metadataSourceLabel.contains("domains::") == false)
        #expect(overview.routeStories.count == 1)
        #expect(overview.routeStories.first?.operation == "git_status")
        #expect(overview.routeStories.first?.kind == "active_route")
        #expect(overview.routeStories.first?.title == "Inspect Git Status is using a governed replacement route")
        #expect(overview.routeStories.first?.drillDownLabel == "Inspect route evidence")

        let observe = overview.modularityOperations.first { $0.name == "observe" }
        #expect(observe?.isLocked == true)
        #expect(observe?.capabilityAudience == "kernel_evolution")
        #expect(observe?.capabilityReplacementClass == "kernel_evolution_only")
        #expect(observe?.capabilityDefaultVisibility == "inspect_only")
        #expect(observe?.canReplace == false)
        #expect(observe?.readinessNextActionLabel == "Observe only")
        #expect(observe?.rollbackAvailable == false)

        let resourcesGroup = overview.discovery.groups.first { $0.id == "resources_memory" }
        #expect(resourcesGroup?.operations.contains { $0.name == "git_status" } == true)
        #expect(resourcesGroup?.ownerSummary == "1 replaceable")
        #expect(resourcesGroup?.ownerSummary.contains("locked") == false)
        #expect(overview.discovery.groups.allSatisfy { group in
            group.operations.allSatisfy(\.isAgentFunctionalCapability)
        })
        let engineGroup = overview.discovery.engineGroups.first { group in
            group.operations.contains { $0.name == "observe" }
        }
        #expect(engineGroup?.ownerSummary == "1 locked action")
        #expect(overview.discovery.engineGroups.contains { !$0.functions.isEmpty })
        #expect(overview.capabilityVisibility?.projection.rawResourceIdsReturned == false)
        #expect(overview.capabilityVisibility?.projection.rawAuthorityIdsReturned == false)
        #expect(overview.capabilityVisibility?.operationList.complete == true)
        #expect(overview.capabilityVisibility?.resourceScan.complete == true)
    }

    @Test("Present empty capability projection stays authoritative")
    func presentEmptyCapabilityProjectionStaysAuthoritative() {
        var visibility = AgentCockpitViewModelTests.capabilityCockpitOverview()
        visibility.operations = []
        visibility.operationList.totalOperations = 0
        visibility.operationList.returnedOperations = 0
        visibility.operationList.complete = true
        visibility.operationList.truncated = false
        visibility.summary.totalOperations = 0
        visibility.summary.returnedOperations = 0
        visibility.summary.operationListComplete = true
        visibility.summary.operationListTruncated = false

        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(functionHealth: "Unhealthy"),
            resources: [],
            capabilityVisibility: visibility,
            connectionState: .connected
        )

        #expect(overview.discovery.agentOperationCount == 0)
        #expect(overview.discovery.groups.isEmpty)
        #expect(overview.discovery.engineOperationCount == 0)
        #expect(overview.discovery.engineFunctionCount == 1)
        #expect(!overview.discovery.engineGroups.isEmpty)
        #expect(overview.status.kind == .ready)
        let summary = AgentCockpitPresentation.dashboardSummary(for: overview)
        #expect(summary.agentActions.value == 0)
        #expect(summary.agentActions.isComplete)
        #expect(summary.engineInterfaces == 1)
    }

    @Test("Projection marks missing schema evidence")
    func projectionMarksMissingSchemaEvidence() {
        let snapshot = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "local.echo::reply",
                        "ownerWorker": "local.echo",
                        "description": "Reply from local echo",
                        "visibility": "Agent",
                        "effectClass": "PureRead",
                        "riskLevel": "Low",
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
        #expect(overview.discovery.engineGroups.first?.missingSchemaCount == 1)
    }

    @Test("Projection keeps internal catalog schema gaps out of operation cockpit status")
    func projectionKeepsInternalCatalogSchemaGapsOutOfOperationCockpitStatus() {
        let snapshot = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "internal.catalog::probe",
                        "ownerWorker": "internal.catalog",
                        "description": "Internal catalog probe",
                        "visibility": "System",
                        "effectClass": "PureRead",
                        "riskLevel": "Low",
                        "health": "Healthy",
                        "tags": ["internal"]
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
            discoveryReports: [
                Fixtures.sampleResource(
                    id: "catalog_discovery_report:2:invocation-2",
                    kind: .catalogDiscoveryReport,
                    lifecycle: "passed"
                )
            ],
            capabilityVisibility: AgentCockpitViewModelTests.capabilityCockpitOverview(),
            connectionState: .connected
        )

        #expect(overview.status.kind == .idle)
        #expect(overview.discovery.title == "Verified")
        #expect(overview.discovery.missingSchemaCount == 0)
        #expect(overview.discovery.catalogDecodeIssueCount == 0)
        #expect(overview.discovery.groups.allSatisfy { $0.missingSchemaCount == 0 })
        #expect(overview.discovery.agentOperationCount == 1)
        #expect(overview.discovery.engineOperationCount == 1)
        #expect(overview.discovery.engineFunctionCount == 1)
    }

    @Test("Projection treats missing operation pool classification as a cockpit issue")
    func projectionTreatsMissingOperationPoolClassificationAsIssue() {
        var visibility = AgentCockpitViewModelTests.capabilityCockpitOverview()
        visibility.operations[0].capabilityPool = nil

        let overview = AgentCockpitProjection.project(
            snapshot: Fixtures.sampleCatalogSnapshot(),
            resources: [],
            capabilityVisibility: visibility,
            connectionState: .connected
        )

        #expect(overview.status.kind == .degraded)
        #expect(overview.status.title == "Operations Need Review")
        #expect(overview.status.detail.contains("missing capability-pool classification"))
        #expect(overview.issueCount == 1)
        let git = overview.modularityOperations.first { $0.name == "git_status" }
        #expect(git?.capabilityAudience == "unknown")
        #expect(git?.capabilityReplacementClass == "unknown")
        #expect(git?.capabilityMinimalityDecision == "unknown")
    }

    @Test("Projection treats server snake-case schema evidence as complete")
    func projectionTreatsServerSnakeCaseSchemaEvidenceAsComplete() {
        let snapshot = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "context_control::snapshot",
                        "owner_worker": "context_control",
                        "description": "Read a provider-safe context snapshot",
                        "visibility": "System",
                        "effect_class": "PureRead",
                        "risk_level": "Low",
                        "health": "Healthy",
                        "request_schema": ["type": "object"],
                        "response_schema": ["type": "object"],
                        "opaque_response": false
                    ])
                ],
                workers: [],
                triggers: [],
                triggerTypes: []
            ),
            currentRevision: 4,
            nextRevision: 5,
            hasMore: false
        )

        let overview = AgentCockpitProjection.project(
            snapshot: snapshot,
            resources: [],
            discoveryReports: [
                Fixtures.sampleResource(
                    id: "catalog_discovery_report:4:invocation-2",
                    kind: .catalogDiscoveryReport,
                    lifecycle: "passed"
                )
            ],
            connectionState: .connected
        )

        #expect(overview.status.kind == .idle)
        #expect(overview.discovery.title == "Verified")
        #expect(overview.discovery.missingSchemaCount == 0)
        #expect(overview.discovery.engineGroups.first?.missingSchemaCount == 0)
        #expect(overview.functions.first?.ownerWorker == "context_control")
        #expect(overview.functions.first?.effectClass == "PureRead")
        #expect(overview.functions.first?.riskLevel == "Low")
        #expect(overview.functions.first?.schemaComplete == true)
        let summary = AgentCockpitPresentation.dashboardSummary(for: overview)
        #expect(summary.agentActions.value == nil)
        #expect(summary.agentActions.displayValue == "—")
        #expect(
            summary.agentActions.phrase(
                singular: "agent action",
                plural: "agent actions"
            ) == "Agent actions unavailable"
        )
        #expect(summary.engineActions.value == nil)
        #expect(summary.engineInterfaces == 1)
    }

    @Test("Projection explains built-in interfaces without workers or triggers")
    func projectionExplainsBuiltInInterfacesWithoutWorkersOrTriggers() {
        let snapshot = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "context_control::snapshot",
                        "ownerWorker": "context_control",
                        "description": "Read a provider-safe context snapshot",
                        "visibility": "System",
                        "effectClass": "PureRead",
                        "riskLevel": "Low",
                        "health": "Healthy",
                        "requestSchema": ["type": "object"],
                        "responseSchema": ["type": "object"]
                    ])
                ],
                workers: [],
                triggers: [],
                triggerTypes: []
            ),
            currentRevision: 4,
            nextRevision: 5,
            hasMore: false
        )

        let overview = AgentCockpitProjection.project(
            snapshot: snapshot,
            resources: [],
            connectionState: .connected
        )

        let group = overview.discovery.engineGroups.first
        #expect(group?.title == "Session & Context")
        #expect(group?.ownerSummary == "Built-in engine interfaces")
        #expect(group?.workerTriggerExplanation?.contains("interfaces are built into the engine") == true)
        #expect(
            overview.discovery.detail
                == "Agent action inventory unavailable; 1 engine interface remains inspectable"
        )
        #expect(
            AgentCockpitPresentation.verificationDetail(for: overview.discovery)
                == "Agent action inventory is unavailable. 1 engine interface remains visible for diagnostics."
        )
    }

    @Test("Projection reports malformed catalog entries as degraded")
    func projectionReportsMalformedCatalogEntriesAsDegraded() {
        let snapshot = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "local.echo::reply",
                        "ownerWorker": "local.echo",
                        "requestSchema": ["type": "object"],
                        "responseSchema": ["type": "object"]
                    ]),
                    AnyCodable([
                        "ownerWorker": "local.echo",
                        "requestSchema": ["type": "object"]
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
            discoveryReports: [
                Fixtures.sampleResource(
                    id: "catalog_discovery_report:2:invocation-2",
                    kind: .catalogDiscoveryReport,
                    lifecycle: "passed"
                )
            ],
            connectionState: .connected
        )
        let summary = AgentCockpitPresentation.dashboardSummary(for: overview)

        #expect(overview.status.kind == .degraded)
        #expect(overview.status.title == "Operations Need Review")
        #expect(overview.discovery.title == "Operations Need Review")
        #expect(overview.discovery.catalogDecodeIssueCount == 1)
        #expect(overview.discovery.reports.first?.lifecycle == "passed")
        #expect(summary.statusKind == .degraded)
        #expect(summary.title == "Operations Need Review")
        #expect(summary.detail == "1 capability entry could not be decoded")
    }

}
