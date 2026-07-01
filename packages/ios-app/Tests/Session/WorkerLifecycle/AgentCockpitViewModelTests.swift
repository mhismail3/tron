import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Agent Cockpit View Model Tests")
struct AgentCockpitViewModelTests {
    @Test("Refresh loads catalog and lifecycle resources")
    func refreshLoadsCatalogAndResources() async {
        let repository = MockWorkerLifecycleRepository()
        repository.catalog = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
            currentRevision: 7,
            nextRevision: 8,
            hasMore: false
        )
        repository.resourcesByKind[.package] = [
            Self.resource(id: "worker_package:local.echo:1.0.0", kind: .package, lifecycle: "installed")
        ]
        repository.resourcesByKind[.uiSurface] = [
            Self.resource(id: "ui_surface:surface-1", kind: .uiSurface, lifecycle: "active")
        ]
        repository.resourcesByKind[.catalogDiscoveryReport] = [
            Self.resource(id: "catalog_discovery_report:7:invocation-1", kind: .catalogDiscoveryReport, lifecycle: "passed")
        ]
        repository.moduleActivity = Self.moduleActivityOverview()
        repository.inspections["ui_surface:surface-1"] = Self.surfaceInspection()
        let viewModel = AgentCockpitViewModel()

        await viewModel.refresh(
            repository: repository,
            sessionId: "test-session",
            workspaceId: "test-workspace",
            connectionState: .connected
        )

        #expect(repository.overviewCallCount == 1)
        #expect(repository.listedKinds.contains(.package))
        #expect(repository.listedKinds.contains(.uiSurface))
        #expect(repository.listedKinds.contains(.catalogDiscoveryReport))
        #expect(viewModel.overview.currentRevision == 7)
        #expect(viewModel.overview.packages.first?.packageId == "local.echo")
        #expect(viewModel.overview.discovery.reports.first?.resourceId == "catalog_discovery_report:7:invocation-1")
        #expect(viewModel.overview.runtimeSurfaces.first?.surface.title == "Runtime")
        #expect(viewModel.overview.runtimeSurfaces.first?.resourceRef.kind == "ui_surface")
        #expect(repository.moduleActivityOverviewCallCount == 1)
        #expect(repository.lastModuleActivitySessionId == "test-session")
        #expect(repository.lastModuleActivityWorkspaceId == "test-workspace")
        #expect(viewModel.overview.moduleActivity?.summary.active == 1)
        #expect(viewModel.overview.activity.first?.title == "Active module runtime")
        #expect(viewModel.overview.activity.first?.status == "active")
        #expect(viewModel.lastError == nil)
    }

    @Test("Refresh failure preserves last overview and reports degraded status")
    func refreshFailurePreservesLastOverviewAndReportsDegradedStatus() async {
        let repository = MockWorkerLifecycleRepository()
        repository.catalog = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(
                functions: [
                    AnyCodable([
                        "id": "local.echo::reply",
                        "owner_worker": "local.echo",
                        "request_schema": ["type": "object"],
                        "response_schema": ["type": "object"]
                    ])
                ],
                workers: [
                    AnyCodable([
                        "id": "local.echo",
                        "kind": "External",
                        "lifecycle": "Ready"
                    ])
                ],
                triggers: [],
                triggerTypes: []
            ),
            currentRevision: 7,
            nextRevision: 8,
            hasMore: false
        )
        let viewModel = AgentCockpitViewModel()
        await viewModel.refresh(
            repository: repository,
            sessionId: "test-session",
            workspaceId: "test-workspace",
            connectionState: .connected
        )

        repository.listErrorsByKind[.package] = MockWorkerLifecycleError.failure("package resource refresh failed")
        await viewModel.refresh(
            repository: repository,
            sessionId: "test-session",
            workspaceId: "test-workspace",
            connectionState: .connected
        )

        #expect(viewModel.overview.status.kind == .degraded)
        #expect(viewModel.overview.status.title == "Refresh Failed")
        #expect(viewModel.overview.status.title != "Idle")
        #expect(viewModel.overview.currentRevision == 7)
        #expect(viewModel.overview.workers.first?.id == "local.echo")
        #expect(viewModel.lastError == "package resource refresh failed")
    }

    @Test("Verify catalog discovery creates conformance report and refreshes")
    func verifyCatalogDiscoveryCreatesReportAndRefreshes() async {
        let repository = MockWorkerLifecycleRepository()
        repository.catalog = CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
            currentRevision: 7,
            nextRevision: 8,
            hasMore: false
        )
        let viewModel = AgentCockpitViewModel()

        await viewModel.verifyCatalogDiscovery(
            repository: repository,
            sessionId: "session-1",
            workspaceId: "workspace-1",
            connectionState: .connected
        )

        #expect(repository.createdCatalogReportReason == "runtime cockpit verification")
        #expect(repository.createdCatalogReportSessionId == "session-1")
        #expect(repository.createdCatalogReportWorkspaceId == "workspace-1")
        #expect(repository.overviewCallCount == 1)
        #expect(viewModel.lastError == nil)
    }

    @Test("Install proposal fetches manifest from resource inspection")
    func installProposalFetchesManifestFromInspection() async throws {
        let repository = MockWorkerLifecycleRepository()
        repository.inspections["worker_package_proposal:local.echo:1.0.0:invocation-1"] = ResourceInspectResultDTO(
            inspection: EngineResourceInspectionDTO(
                resource: Self.resource(
                    id: "worker_package_proposal:local.echo:1.0.0:invocation-1",
                    kind: .proposal,
                    lifecycle: "proposed"
                ),
                versions: [
                    EngineResourceVersionDTO(
                        versionId: "version-1",
                        resourceId: "worker_package_proposal:local.echo:1.0.0:invocation-1",
                        parentVersionId: nil,
                        contentHash: nil,
                        state: "available",
                        payload: [
                            "manifest": AnyCodable([
                                "packageId": "local.echo",
                                "packageVersion": "1.0.0",
                                "futureField": ["kept": true]
                            ])
                        ],
                        locations: [],
                        createdByInvocationId: nil,
                        traceId: nil,
                        createdAt: nil
                    )
                ],
                outgoingLinks: [],
                incomingLinks: [],
                events: []
            )
        )
        let viewModel = AgentCockpitViewModel()
        let action = AgentCockpitAction(
            id: "install:worker_package_proposal:local.echo:1.0.0:invocation-1",
            kind: .installProposal,
            title: "Install",
            packageId: "local.echo",
            packageVersion: "1.0.0",
            proposalResourceId: "worker_package_proposal:local.echo:1.0.0:invocation-1",
            launchAttemptResourceId: nil,
            reason: "user approved package proposal",
            disabledReason: nil,
            isDestructive: false
        )

        let result = try await viewModel.perform(
            action,
            repository: repository,
            sessionId: "session-1",
            workspaceId: "workspace-1"
        )

        #expect(result.status == "installed")
        #expect(repository.inspectCallIds == ["worker_package_proposal:local.echo:1.0.0:invocation-1"])
        #expect(repository.installedManifest?["packageId"]?.stringValue == "local.echo")
        #expect(repository.installedSessionId == "session-1")
        #expect(repository.installedWorkspaceId == "workspace-1")
    }

    @Test("Request confirmation ignores disabled actions")
    func requestConfirmationIgnoresDisabledActions() {
        let viewModel = AgentCockpitViewModel()
        let disabled = AgentCockpitAction(
            id: "launch:disabled",
            kind: .launchWorker,
            title: "Launch",
            packageId: "local.echo",
            packageVersion: "1.0.0",
            proposalResourceId: nil,
            launchAttemptResourceId: nil,
            reason: "test",
            disabledReason: "Package must be enabled before launch",
            isDestructive: false
        )

        viewModel.requestConfirmation(for: disabled)

        #expect(viewModel.pendingConfirmation == nil)
    }

    private static func resource(
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
            updatedAt: nil
        )
    }

    private static func surfaceInspection() -> ResourceInspectResultDTO {
        ResourceInspectResultDTO(
            inspection: EngineResourceInspectionDTO(
                resource: EngineResourceDTO(
                    resourceId: "ui_surface:surface-1",
                    kind: WorkerLifecycleResourceKind.uiSurface.rawValue,
                    schemaId: nil,
                    scope: AnyCodable("system"),
                    ownerWorkerId: "ui::runtime",
                    ownerActorId: "system",
                    lifecycle: "active",
                    policy: nil,
                    currentVersionId: "surface-version-1",
                    traceId: nil,
                    createdByInvocationId: nil,
                    createdAt: nil,
                    updatedAt: "2100-01-01T00:00:00Z"
                ),
                versions: [
                    EngineResourceVersionDTO(
                        versionId: "surface-version-1",
                        resourceId: "ui_surface:surface-1",
                        parentVersionId: nil,
                        contentHash: nil,
                        state: "available",
                        payload: [
                            "surfaceId": AnyCodable("surface-1"),
                            "title": AnyCodable("Runtime"),
                            "purpose": AnyCodable("cockpit"),
                            "schemaVersion": AnyCodable(1),
                            "layout": AnyCodable([
                                "type": "Text",
                                "props": ["text": "Live runtime surface"]
                            ]),
                            "actions": AnyCodable([]),
                            "expiresAt": AnyCodable("2100-01-01T00:00:00Z")
                        ],
                        locations: [],
                        createdByInvocationId: nil,
                        traceId: nil,
                        createdAt: nil
                    )
                ],
                outgoingLinks: [],
                incomingLinks: [],
                events: []
            )
        )
    }

    static func moduleActivityOverview() -> ModuleActivityOverviewDTO {
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
                    title: "Active module runtime",
                    detail: "Server-owned projection",
                    authorityLabels: ["grant redacted", "derived runtime grant required"],
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

    static func agentBriefingOverview() -> AgentBriefingOverviewDTO {
        AgentBriefingOverviewDTO(
            schemaVersion: "tron.agent_briefing.overview.v1",
            operation: "agent_briefing_overview",
            summary: AgentBriefingSummaryDTO(
                title: "Tron has active work",
                detail: "1 active, 0 waiting on review, 0 blocked, 1 total records.",
                activeWorkCount: 1,
                needsYouCount: 0,
                weakPointCount: 0,
                activityCount: 1,
                degraded: false
            ),
            sections: [
                AgentBriefingSectionDTO(
                    id: "active_work",
                    title: "Active work",
                    question: "What is currently in motion?",
                    narrative: "Active module runtime work is in progress.",
                    items: [
                        AgentBriefingItemDTO(
                            id: "briefing-item-1",
                            title: "Active module runtime",
                            detail: "Server-owned projection",
                            status: "active",
                            evidence: AgentBriefingEvidenceDTO(
                                label: "Evidence 1",
                                resourceKind: "module_runtime_state",
                                updatedAt: "2026-06-20T12:00:00Z",
                                providerSafe: true
                            )
                        )
                    ],
                    emptyState: "No active work is in progress.",
                    drilldownAvailable: true
                )
            ],
            scope: AgentBriefingScopeDTO(
                sessionScoped: true,
                workspaceScoped: false,
                exactScopeRequired: true,
                payloadScopeTrusted: false
            ),
            projection: AgentBriefingProjectionPolicyDTO(
                allowlist: "agent_briefing_metadata_redacted_v1",
                serverOwnedTruth: true,
                projectionOnly: true,
                autonomyBehaviorCreated: false,
                metadataOnly: true,
                rawPayloadsReturned: false,
                rawCommandsReturned: false,
                rawLogsReturned: false,
                promptBodiesReturned: false,
                fileContentsReturned: false,
                absolutePathsReturned: false,
                grantIdsReturned: false,
                authorityIdsReturned: false,
                traceIdsReturned: false,
                invocationIdsReturned: false,
                tokenLikeMaterialReturned: false,
                boundedItems: true,
                sourceProjection: "module_activity_overview"
            )
        )
    }
}

@MainActor
private final class MockWorkerLifecycleRepository: WorkerLifecycleRepository {
    var catalog = CatalogWatchSnapshotDTO(
        changes: [],
        snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
        currentRevision: nil,
        nextRevision: nil,
        hasMore: false
    )
    var resourcesByKind: [WorkerLifecycleResourceKind: [EngineResourceDTO]] = [:]
    var listErrorsByKind: [WorkerLifecycleResourceKind: Error] = [:]
    var inspections: [String: ResourceInspectResultDTO] = [:]
    var moduleActivity = AgentCockpitViewModelTests.moduleActivityOverview()
    var agentBriefing = AgentCockpitViewModelTests.agentBriefingOverview()

    var overviewCallCount = 0
    var moduleActivityOverviewCallCount = 0
    var lastModuleActivitySessionId: String?
    var lastModuleActivityWorkspaceId: String?
    var agentBriefingOverviewCallCount = 0
    var lastAgentBriefingSessionId: String?
    var lastAgentBriefingWorkspaceId: String?
    var listedKinds: [WorkerLifecycleResourceKind] = []
    var inspectCallIds: [String] = []
    var installedManifest: [String: AnyCodable]?
    var installedSessionId: String?
    var installedWorkspaceId: String?
    var createdCatalogReportReason: String?
    var createdCatalogReportSessionId: String?
    var createdCatalogReportWorkspaceId: String?

    func overview(afterRevision: UInt64?) async throws -> CatalogWatchSnapshotDTO {
        overviewCallCount += 1
        return catalog
    }

    func listResources(
        kind: WorkerLifecycleResourceKind,
        lifecycle: String?,
        limit: UInt64
    ) async throws -> ResourceListResultDTO {
        listedKinds.append(kind)
        if let error = listErrorsByKind[kind] {
            throw error
        }
        return ResourceListResultDTO(resources: resourcesByKind[kind] ?? [])
    }

    func inspectResource(_ resourceId: String) async throws -> ResourceInspectResultDTO {
        inspectCallIds.append(resourceId)
        return inspections[resourceId] ?? ResourceInspectResultDTO(inspection: nil)
    }

    func moduleActivityOverview(
        limit: UInt64,
        sessionId: String?,
        workspaceId: String?
    ) async throws -> ModuleActivityOverviewDTO {
        moduleActivityOverviewCallCount += 1
        lastModuleActivitySessionId = sessionId
        lastModuleActivityWorkspaceId = workspaceId
        return moduleActivity
    }

    func agentBriefingOverview(
        limit: UInt64,
        sessionId: String?,
        workspaceId: String?
    ) async throws -> AgentBriefingOverviewDTO {
        agentBriefingOverviewCallCount += 1
        lastAgentBriefingSessionId = sessionId
        lastAgentBriefingWorkspaceId = workspaceId
        return agentBriefing
    }

    func proposePackageChange(
        manifest: [String: AnyCodable],
        summary: String,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "proposed")
    }

    func installPackage(
        manifest: [String: AnyCodable],
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        installedManifest = manifest
        installedSessionId = sessionId
        installedWorkspaceId = workspaceId
        return WorkerLifecycleResultDTO(status: "installed")
    }

    func enablePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "enabled")
    }

    func disablePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "disabled")
    }

    func launchWorker(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "launched")
    }

    func stopWorker(
        launchAttemptResourceId: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "stopped")
    }

    func createCatalogDiscoveryReport(
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> CatalogDiscoveryReportResultDTO {
        createdCatalogReportReason = reason
        createdCatalogReportSessionId = sessionId
        createdCatalogReportWorkspaceId = workspaceId
        return CatalogDiscoveryReportResultDTO(
            status: "passed",
            reportResourceId: "catalog_discovery_report:7:invocation-1",
            streamCursor: 10,
            summary: nil,
            resourceRefs: nil
        )
    }

    func retirePackage(
        packageId: String,
        packageVersion: String,
        reason: String?,
        sessionId: String?,
        workspaceId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerLifecycleResultDTO {
        WorkerLifecycleResultDTO(status: "retired")
    }
}

private enum MockWorkerLifecycleError: LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case let .failure(message):
            return message
        }
    }
}
