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
        #expect(overview.functions.first?.requestSchemaJSON?.contains(#""type" : "object""#) == true)
        #expect(overview.functions.first?.responseSchemaJSON?.contains(#""type" : "object""#) == true)
        #expect(overview.triggers.first?.targetFunction == "local.echo::reply")
        #expect(overview.packages.first?.packageId == "local.echo")
        #expect(overview.discovery.title == "Verified")
        #expect(overview.discovery.families.first?.id == "local.echo")
        #expect(overview.discovery.groups.first?.title == "Other Capabilities")
        #expect(overview.discovery.groups.first?.functionCount == 1)
        #expect(overview.discovery.reports.first?.lifecycle == "passed")
        #expect(overview.activity.isEmpty)
    }

    @Test("Projection renders server-owned module activity from resource facts")
    func projectionRendersServerOwnedModuleActivity() {
        let overview = AgentCockpitProjection.project(
            snapshot: sampleCatalogSnapshot(),
            resources: [
                sampleResource(
                    id: "worker_package_proposal:local.echo:1.0.0:invocation-1",
                    kind: .proposal,
                    lifecycle: "proposed"
                )
            ],
            moduleActivity: sampleModuleActivityOverview(),
            connectionState: .connected
        )

        #expect(overview.activity.count == 1)
        #expect(overview.activity.first?.title == "Runtime envelope")
        #expect(overview.activity.first?.status == "active")
        #expect(overview.activity.first?.resourceKind == "module_runtime_state")
        #expect(overview.activity.first?.authorityLabels.contains("grant redacted") == true)
        #expect(overview.activity.first?.touchedResources.first?.label == "output refs")
        #expect(overview.moduleActivity?.projection.rawPayloadsReturned == false)
    }

    @Test("Projection renders capability cockpit operation ownership and attempts without raw owner text")
    func projectionRendersCapabilityCockpitVisibility() {
        let overview = AgentCockpitProjection.project(
            snapshot: sampleCatalogSnapshot(),
            resources: [],
            discoveryReports: [
                sampleResource(
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
        #expect(overview.invokableUnitCount == 1)
        #expect(overview.invokableUnitLabel == "Agent operations")
        #expect(overview.discovery.agentOperationCount == 1)
        #expect(overview.discovery.engineOperationCount == 1)
        #expect(overview.discovery.internalContractCount == 1)
        let git = overview.modularityOperations.first { $0.name == "git_status" }
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
        #expect(git?.ownerLabel.contains("domains::") == false)
        #expect(git?.metadataSourceLabel.contains("domains::") == false)
        #expect(overview.routeStories.count == 1)
        #expect(overview.routeStories.first?.operation == "git_status")
        #expect(overview.routeStories.first?.kind == "active_route")
        #expect(overview.routeStories.first?.title == "git_status is using a governed replacement route")
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
        #expect(engineGroup?.ownerSummary == "1 locked operation")
        #expect(overview.discovery.engineGroups.contains { !$0.functions.isEmpty })
        #expect(overview.capabilityVisibility?.projection.rawResourceIdsReturned == false)
        #expect(overview.capabilityVisibility?.projection.rawAuthorityIdsReturned == false)
        #expect(overview.capabilityVisibility?.operationList.complete == true)
        #expect(overview.capabilityVisibility?.resourceScan.complete == true)
    }

    @Test("Projection preserves degraded module activity state")
    func projectionPreservesDegradedModuleActivityState() {
        let overview = AgentCockpitProjection.project(
            snapshot: sampleCatalogSnapshot(),
            resources: [],
            moduleActivity: sampleDegradedModuleActivityOverview(),
            connectionState: .connected
        )

        #expect(overview.activity.count == 1)
        #expect(overview.activity.first?.status == "degraded")
        #expect(overview.activity.first?.systemImage == "exclamationmark.triangle")
        #expect(overview.moduleActivity?.summary.degraded == 1)
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
        #expect(overview.discovery.groups.first?.missingSchemaCount == 1)
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
                sampleResource(
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
        #expect(overview.invokableUnitLabel == "Agent operations")
        #expect(overview.invokableUnitCount == 1)
        #expect(overview.discovery.agentOperationCount == 1)
        #expect(overview.discovery.engineOperationCount == 1)
        #expect(overview.discovery.internalContractCount == 1)
    }

    @Test("Projection treats missing operation pool classification as a cockpit issue")
    func projectionTreatsMissingOperationPoolClassificationAsIssue() {
        var visibility = AgentCockpitViewModelTests.capabilityCockpitOverview()
        visibility.operations[0].capabilityPool = nil

        let overview = AgentCockpitProjection.project(
            snapshot: sampleCatalogSnapshot(),
            resources: [],
            capabilityVisibility: visibility,
            connectionState: .connected
        )

        #expect(overview.status.kind == .degraded)
        #expect(overview.status.title == "Operations Need Review")
        #expect(overview.status.detail.contains("missing capability-pool classification"))
        let git = overview.modularityOperations.first { $0.name == "git_status" }
        #expect(git?.capabilityAudience == "unknown")
        #expect(git?.capabilityReplacementClass == "unknown")
        #expect(git?.capabilityEvolutionPath == "Capability-pool classification is missing from the server projection.")
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
                sampleResource(
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
        #expect(overview.discovery.groups.first?.missingSchemaCount == 0)
        #expect(overview.invokableUnitCount == 1)
        #expect(overview.invokableUnitLabel == "Functions")
        #expect(overview.functions.first?.ownerWorker == "context_control")
        #expect(overview.functions.first?.effectClass == "PureRead")
        #expect(overview.functions.first?.riskLevel == "Low")
        #expect(overview.functions.first?.schemaComplete == true)
    }

    @Test("Projection explains built-in operations without workers or triggers")
    func projectionExplainsBuiltInOperationsWithoutWorkersOrTriggers() {
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

        let group = overview.discovery.groups.first
        #expect(group?.title == "Session & Context")
        #expect(group?.ownerSummary == "Built-in engine operations")
        #expect(group?.workerTriggerExplanation?.contains("built-in engine operations") == true)
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
                sampleResource(
                    id: "catalog_discovery_report:2:invocation-2",
                    kind: .catalogDiscoveryReport,
                    lifecycle: "passed"
                )
            ],
            connectionState: .connected
        )

        #expect(overview.status.kind == .degraded)
        #expect(overview.status.title == "Operations Need Review")
        #expect(overview.discovery.title == "Operations Need Review")
        #expect(overview.discovery.catalogDecodeIssueCount == 1)
        #expect(overview.discovery.reports.first?.lifecycle == "passed")
    }

    @Test("Cockpit presentation keeps top-level labels user-facing")
    func cockpitPresentationKeepsTopLevelLabelsUserFacing() {
        let overview = AgentCockpitProjection.project(
            snapshot: sampleCatalogSnapshot(),
            resources: [],
            discoveryReports: [
                sampleResource(
                    id: "catalog_discovery_report:2:invocation-2",
                    kind: .catalogDiscoveryReport,
                    lifecycle: "passed"
                )
            ],
            capabilityVisibility: AgentCockpitViewModelTests.capabilityCockpitOverview(),
            moduleActivity: sampleModuleActivityOverview(),
            connectionState: .connected
        )

        let topLevelStrings = [
            AgentCockpitPresentation.verificationTitle(for: overview.discovery),
            AgentCockpitPresentation.verificationDetail(for: overview.discovery),
            AgentCockpitPresentation.verificationPhrase(for: overview.discovery.latestReport),
            AgentCockpitPresentation.verificationStatus(for: overview.discovery.latestReport),
            AgentCockpitPresentation.workKindLabel(overview.moduleActivity?.resources.first?.kind ?? ""),
            AgentCockpitPresentation.workStateLine(
                kind: overview.activity.first?.resourceKind ?? "",
                status: overview.activity.first?.status ?? ""
            )
        ]

        #expect(AgentCockpitPresentation.hiddenTopLevelTerms(in: topLevelStrings).isEmpty)
        #expect(topLevelStrings.contains("Operations verified"))
        #expect(topLevelStrings.contains("Verified"))
        #expect(topLevelStrings.contains("Runtime"))
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
                        "ownerWorker": "local.echo",
                        "description": "Reply from local echo",
                        "visibility": "Agent",
                        "effectClass": "PureRead",
                        "riskLevel": "Low",
                        "health": functionHealth,
                        "tags": ["echo"],
                        "requestSchema": ["type": "object"],
                        "responseSchema": ["type": "object"]
                    ])
                ],
                workers: [
                    AnyCodable([
                        "id": "local.echo",
                        "kind": "External",
                        "lifecycle": "Ready",
                        "ownerActor": "system",
                        "authorityGrant": "engine-transport",
                        "namespaceClaims": ["local.echo"],
                        "visibility": "System"
                    ])
                ],
                triggers: [
                    AnyCodable([
                        "id": "local.echo.tick",
                        "ownerWorker": "local.echo",
                        "triggerType": "cron",
                        "targetFunction": "local.echo::reply",
                        "deliveryMode": "Async",
                        "visibility": "System"
                    ])
                ],
                triggerTypes: [
                    AnyCodable([
                        "id": "cron",
                        "ownerWorker": "local.echo",
                        "description": "Cron trigger",
                        "allowed_deliveryModes": ["Async"],
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

    private func sampleModuleActivityOverview() -> ModuleActivityOverviewDTO {
        ModuleActivityOverviewDTO(
            schemaVersion: "tron.module_activity.overview.v1",
            operation: "module_activity_overview",
            summary: ModuleActivitySummaryDTO(
                total: 1,
                active: 1,
                waiting: 0,
                blocked: 0,
                ready: 0,
                recorded: 0,
                title: "Module work active",
                detail: "1 module runtime activities are active."
            ),
            timeline: [
                ModuleActivityItemDTO(
                    id: "module_runtime_state:version-1",
                    resourceId: "module_runtime_state:runtime-1",
                    resourceKind: "module_runtime_state",
                    status: "active",
                    state: "running",
                    title: "Runtime envelope",
                    detail: "Server-owned projection",
                    authorityLabels: ["grant redacted"],
                    touchedResources: [
                        ModuleActivityResourceTouchDTO(label: "output refs", total: 1, truncated: false)
                    ],
                    rollbackStatus: ModuleActivityGateStatusDTO(label: "Rollback", state: "not_declared", blocked: false, waiting: false),
                    quarantineStatus: ModuleActivityGateStatusDTO(label: "Quarantine", state: "clear", blocked: false, waiting: false),
                    runtimeAuthorizationStatus: ModuleActivityGateStatusDTO(label: "Runtime authorization", state: "allowed", blocked: false, waiting: false),
                    updatedAt: "2026-06-20T12:00:00Z"
                )
            ],
            blocked: [],
            waiting: [],
            resources: [
                ModuleActivityResourceSummaryDTO(kind: "module_runtime_state", total: 1, active: 1, waiting: 0, blocked: 0)
            ],
            projection: ModuleActivityProjectionPolicyDTO(
                allowlist: "module_activity_cockpit_metadata_redacted_v1",
                serverOwnedTruth: true,
                metadataOnly: true,
                rawPayloadsReturned: false,
                rawCommandsReturned: false,
                rawLogsReturned: false,
                fileContentsReturned: false,
                absolutePathsReturned: false,
                grantIdsReturned: false,
                authorityIdsReturned: false,
                traceIdsReturned: false,
                invocationIdsReturned: false,
                tokenLikeMaterialReturned: false,
                boundedItems: true
            )
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

    private func sampleDegradedModuleActivityOverview() -> ModuleActivityOverviewDTO {
        ModuleActivityOverviewDTO(
            schemaVersion: "tron.module_activity.overview.v1",
            operation: "module_activity_overview",
            summary: ModuleActivitySummaryDTO(
                total: 1,
                active: 0,
                waiting: 0,
                blocked: 0,
                degraded: 1,
                ready: 0,
                recorded: 0,
                title: "Module work degraded",
                detail: "1 module activity failed or entered quarantine."
            ),
            timeline: [
                ModuleActivityItemDTO(
                    id: "module_runtime_state:version-2",
                    resourceId: "module_runtime_state:runtime-2",
                    resourceKind: "module_runtime_state",
                    status: "degraded",
                    state: "failed",
                    title: "Runtime envelope",
                    detail: "Server-owned projection",
                    authorityLabels: [],
                    touchedResources: [],
                    rollbackStatus: ModuleActivityGateStatusDTO(label: "Rollback", state: "not_declared", blocked: false, waiting: false),
                    quarantineStatus: ModuleActivityGateStatusDTO(label: "Quarantine", state: "blocked", blocked: true, waiting: false),
                    runtimeAuthorizationStatus: ModuleActivityGateStatusDTO(label: "Runtime authorization", state: "allowed", blocked: false, waiting: false),
                    updatedAt: "2026-06-20T12:00:00Z"
                )
            ],
            blocked: [],
            waiting: [],
            resources: [
                ModuleActivityResourceSummaryDTO(kind: "module_runtime_state", total: 1, active: 0, waiting: 0, blocked: 0)
            ],
            projection: ModuleActivityProjectionPolicyDTO(
                allowlist: "module_activity_cockpit_metadata_redacted_v1",
                serverOwnedTruth: true,
                metadataOnly: true,
                rawPayloadsReturned: false,
                rawCommandsReturned: false,
                rawLogsReturned: false,
                fileContentsReturned: false,
                absolutePathsReturned: false,
                grantIdsReturned: false,
                authorityIdsReturned: false,
                traceIdsReturned: false,
                invocationIdsReturned: false,
                tokenLikeMaterialReturned: false,
                boundedItems: true
            )
        )
    }
}
