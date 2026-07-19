import Testing
@testable import TronMobile

@Suite("Agent Cockpit Issue State Tests")
struct AgentCockpitIssueStateTests {
    @Test("Issue count deduplicates one degraded module activity across timeline, blocked list, and summary")
    func issueCountDeduplicatesDegradedModuleActivity() {
        let overview = AgentCockpitProjection.project(
            snapshot: emptyCatalogSnapshot(),
            resources: [],
            moduleActivity: degradedModuleActivity(),
            connectionState: .connected
        )

        #expect(overview.issueCount == 1)
        #expect(overview.issueDetail == "1 module activity failed or entered quarantine.")
    }

    @Test("Issue count treats failed-closed routing and each incomplete projection boundary as distinct issues")
    func issueCountIncludesRouteAndProjectionFailures() throws {
        var visibility = AgentCockpitViewModelTests.capabilityCockpitOverview()
        var operation = visibility.operations[0]
        var route = try #require(operation.route)
        route.failedClosed = 2
        operation.route = route
        visibility.operations[0] = operation
        visibility.summary.failedClosedRoutes = 2
        visibility.operationList.complete = false
        visibility.operationList.truncated = true
        visibility.resourceScan.complete = false
        visibility.resourceScan.truncated = true

        let overview = AgentCockpitProjection.project(
            snapshot: emptyCatalogSnapshot(),
            resources: [],
            capabilityVisibility: visibility,
            connectionState: .connected
        )

        #expect(overview.issueCount == 3)
        #expect(overview.issueDetail.contains("failed-closed replacement routing"))
    }

    @Test("Refresh failure contributes one issue without replacing preserved state")
    func refreshFailureContributesOneIssue() {
        let failed = AgentCockpitProjection.refreshFailedOverview(
            previous: .empty(connectionState: .connected),
            connectionState: .connected,
            message: "Latest Dashboard refresh failed"
        )

        #expect(failed.issueCount == 1)
        #expect(failed.issueDetail == "Latest Dashboard refresh failed")
    }

    private func emptyCatalogSnapshot() -> CatalogWatchSnapshotDTO {
        CatalogWatchSnapshotDTO(
            changes: [],
            snapshot: CatalogSnapshotDTO(functions: [], workers: [], triggers: [], triggerTypes: []),
            currentRevision: 1,
            nextRevision: 1,
            hasMore: false
        )
    }

    private func degradedModuleActivity() -> ModuleActivityOverviewDTO {
        let item = ModuleActivityItemDTO(
            id: "module_runtime_state:version-2",
            resourceId: "module_runtime_state:runtime-2",
            resourceKind: "module_runtime_state",
            status: "degraded",
            state: "failed",
            title: "Runtime envelope",
            detail: "Server-owned projection",
            authorityLabels: [],
            touchedResources: [],
            rollbackStatus: .init(label: "Rollback", state: "blocked", blocked: true, waiting: false),
            quarantineStatus: .init(label: "Quarantine", state: "blocked", blocked: true, waiting: false),
            runtimeAuthorizationStatus: .init(label: "Runtime authorization", state: "allowed", blocked: false, waiting: false),
            updatedAt: "2026-06-20T12:00:00Z"
        )
        return ModuleActivityOverviewDTO(
            schemaVersion: "tron.module_activity.overview.v1",
            operation: "module_activity_overview",
            summary: .init(
                total: 1,
                active: 0,
                waiting: 0,
                blocked: 1,
                degraded: 1,
                ready: 0,
                recorded: 0,
                title: "Module work degraded",
                detail: "1 module activity failed or entered quarantine."
            ),
            timeline: [item],
            blocked: [item],
            waiting: [],
            resources: [],
            projection: .init(
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
