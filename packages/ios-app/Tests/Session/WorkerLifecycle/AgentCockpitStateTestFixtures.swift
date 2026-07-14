import Foundation
@testable import TronMobile

enum AgentCockpitStateTestFixtures {
    static func sampleCatalogSnapshot(functionHealth: String = "Healthy") -> CatalogWatchSnapshotDTO {
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

    static func sampleResource(
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

    static func sampleModuleActivityOverview() -> ModuleActivityOverviewDTO {
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

    static func samplePackageRow(
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

    static func sampleDegradedModuleActivityOverview() -> ModuleActivityOverviewDTO {
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
