import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Worker Console View Model Tests")
struct WorkerConsoleViewModelTests {
    @Test("Refresh, inspect, typed invoke, stop, and disable use the worker kernel repository")
    func operationalFlowUsesWorkerKernelRepository() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(
            repository: repository,
            connectionState: .connected
        )
        #expect(viewModel.workers.map(\.workerId) == ["research"])
        #expect(viewModel.healthyCount == 1)
        #expect(viewModel.enabledCount == 1)
        #expect(viewModel.unhealthyWorkerCount == 0)
        #expect(repository.snapshotSessionIds.count == 1)
        #expect(repository.snapshotSessionIds[0] == nil)
        #expect(viewModel.availableWorkerTools.map(\.workerId) == ["research"])
        #expect(viewModel.activityRuns.map(\.invocationId) == ["prior-run"])
        #expect(viewModel.activityAttention.map(\.inboxId) == ["inbox-1"])

        await viewModel.select("research", repository: repository)
        #expect(viewModel.inspection?.versions.first?.version == "v1")
        #expect(viewModel.runs.first?.invocationId == "prior-run")
        #expect(viewModel.attention.first?.inboxId == "inbox-1")
        #expect(repository.runLimits == [20, 20])
        #expect(repository.inboxLimits == [20, 20])
        #expect(repository.inboxAttentionFilters == [true, true])

        viewModel.invocationInput = #"{"query":"Tron"}"#
        await viewModel.invoke(repository: repository, connectionState: .connected)
        #expect(repository.invokedWorkerIds == ["research"])
        #expect(repository.lastInput?["query"] as? String == "Tron")
        #expect(viewModel.invocationResult?.contains("accepted") == true)

        await viewModel.stop(repository: repository, connectionState: .connected)
        #expect(repository.stoppedWorkerIds == ["research"])
        #expect(viewModel.selectedWorker?.enabled == true)

        await viewModel.setEnabled(false, repository: repository, connectionState: .connected)
        #expect(repository.enabledMutations == [false])
        #expect(viewModel.selectedWorker?.enabled == false)
    }

    @Test("Engine health count describes current worker state, not delivery attention")
    func engineHealthCountIsCurrentWorkerState() async {
        let repository = MockWorkerKernelRepository()
        repository.health = "failed"
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(repository: repository, connectionState: .connected)

        #expect(viewModel.unhealthyWorkerCount == 1)
        #expect(viewModel.activityAttention.count == 1)

        repository.health = "healthy"
        await viewModel.refresh(repository: repository, connectionState: .connected)

        #expect(viewModel.unhealthyWorkerCount == 0)
        #expect(viewModel.activityAttention.count == 1)
    }

    @Test("Dashboard inventory separates active and retired workers")
    func dashboardInventorySeparatesRetiredWorkers() async {
        let repository = MockWorkerKernelRepository()
        repository.includeRetiredFixture = true
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)

        #expect(viewModel.workers.map(\.workerId) == ["retired-research", "research"])
        #expect(viewModel.activeWorkers.map(\.workerId) == ["research"])
        #expect(viewModel.retiredWorkers.map(\.workerId) == ["retired-research"])
        #expect(viewModel.enabledCount == 1)
    }

    @Test("Architecture metadata resolves beside canonical worker state")
    func architectureMetadataResolvesWithWorkerInspection() async throws {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refreshSummary(repository: repository, connectionState: .connected)
        let architecture = try #require(viewModel.architecture(for: "research"))

        #expect(architecture.modelExposure == "direct")
        #expect(architecture.engineHooks == ["research_context"])
        #expect(viewModel.callers(of: "research").map(\.workerId) == ["research-coordinator"])

        await viewModel.select("research", repository: repository)
        #expect(viewModel.selectedWorkerArchitecture?.workerId == "research")
    }

    @Test("A retired worker exposes every retained version as a restore action")
    func retiredWorkerCanRestoreItsCurrentVersion() async throws {
        let repository = MockWorkerKernelRepository()
        repository.retired = true
        repository.enabled = false
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(repository: repository, connectionState: .connected)
        await viewModel.select("research", repository: repository)
        let worker = try #require(viewModel.selectedWorker)
        let version = try #require(viewModel.inspection?.versions.first)

        #expect(WorkerVersionAction.resolve(worker: worker, version: version) == .restore)
        #expect(WorkerVersionAction.restore.title == "Restore")

        await viewModel.rollback(
            to: worker.activeVersion,
            repository: repository,
            connectionState: .connected
        )

        #expect(repository.rollbackVersions == ["v1"])
        #expect(viewModel.selectedWorker?.retired == false)
        let restoredWorker = try #require(viewModel.selectedWorker)
        #expect(WorkerVersionAction.resolve(worker: restoredWorker, version: version) == nil)
    }

    @Test("Worker monitoring subscribes at the live tail and refreshes only the sidebar summary")
    func monitoringUsesLiveInvalidationsWithoutHistoryReplay() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        let monitor = Task {
            await viewModel.monitorSummary(repository: repository, connectionState: .connected)
        }
        try? await Task.sleep(for: .milliseconds(20))
        NotificationCenter.default.post(name: .workerRunProjectionInvalidated, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        monitor.cancel()
        await monitor.value

        #expect(repository.workerSubscriptionCount == 1)
        #expect(repository.snapshotSessionIds.count == 1)
        #expect(repository.runLimits.isEmpty)
        #expect(repository.inboxLimits.isEmpty)
        #expect(viewModel.monitoringError == nil)
    }

    @Test("Activity history loads every bounded page without duplicating runs")
    func activityHistoryPaginates() async {
        let repository = MockWorkerKernelRepository()
        repository.pagedActivity = true
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(repository: repository, connectionState: .connected)
        #expect(viewModel.activityRuns.map(\.invocationId) == ["prior-run"])
        #expect(viewModel.activityRunsNextOffset == 1)

        await viewModel.loadOlderActivityRuns(repository: repository)
        #expect(viewModel.activityRuns.map(\.invocationId) == ["prior-run", "older-run"])
        #expect(viewModel.activityRunsNextOffset == nil)
        #expect(repository.runOffsets == [nil, 1])
    }

    @Test("Temporary disconnect preserves dashboard state until continuity refresh")
    func temporaryDisconnectPreservesDashboardProjection() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()
        await viewModel.refresh(repository: repository, connectionState: .connected)

        await viewModel.refresh(repository: repository, connectionState: .disconnected)

        #expect(viewModel.workers.map(\.workerId) == ["research"])
        #expect(viewModel.coreToolCount == 0)
        #expect(viewModel.lastError == nil)

        viewModel.resetForServerChange()
        #expect(viewModel.workers.isEmpty)
        #expect(viewModel.engineSnapshot == nil)
    }

    @Test("Transient transport error does not replace worker projection with an error")
    func transientRefreshErrorPreservesDashboardProjection() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()
        await viewModel.refresh(repository: repository, connectionState: .connected)

        repository.snapshotError = EngineConnectionError.notConnected
        await viewModel.refresh(repository: repository, connectionState: .connected)

        #expect(viewModel.workers.map(\.workerId) == ["research"])
        #expect(viewModel.lastError == nil)
    }
}

@MainActor
private final class MockWorkerKernelRepository: WorkerKernelRepository {
    var enabled = true
    var retired = false
    var health = "healthy"
    var invokedWorkerIds: [String] = []
    var cancelledInvocationIds: [String] = []
    var stoppedWorkerIds: [String] = []
    var enabledMutations: [Bool] = []
    var rollbackVersions: [String] = []
    var lastInput: [String: Any]?
    var workerSubscriptionCount = 0
    var snapshotSessionIds: [String?] = []
    var runLimits: [UInt64] = []
    var inboxLimits: [UInt64] = []
    var inboxAttentionFilters: [Bool] = []
    var runOffsets: [UInt64?] = []
    var pagedActivity = false
    var includeRetiredFixture = false
    var snapshotError: Error?

    private var worker: WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: "research",
            name: "Research",
            description: "Recent research worker",
            toolName: "research",
            runnerKind: "command",
            activeVersion: "v1",
            enabled: enabled,
            retired: retired,
            health: enabled ? health : "disabled",
            triggerCount: 1,
            updatedAt: "2026-07-19T12:00:00Z",
            presentation: nil
        )
    }

    private var retiredWorker: WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: "retired-research",
            name: "Retired Research",
            description: "Retained research worker",
            toolName: "retired_research",
            runnerKind: "agent",
            activeVersion: "retired-v1",
            enabled: false,
            retired: true,
            health: "retired",
            triggerCount: 0,
            updatedAt: "2026-07-18T12:00:00Z",
            presentation: nil
        )
    }

    func engineSurfaceSnapshot(
        sessionId: String?,
        relevanceQuery: String?
    ) async throws -> EngineIntrospectionSnapshotDTO {
        if let snapshotError { throw snapshotError }
        snapshotSessionIds.append(sessionId)
        return EngineIntrospectionSnapshotDTO(
            dispatchStopped: false,
            activeEngineHooks: [],
            activeClientActions: [],
            fixedTools: [],
            surface: AgentToolSurfaceDTO(
                catalogRevision: 42,
                surfaceHash: "surface-test",
                fixedToolCount: 29,
                projectedWorkerCount: 1,
                availableWorkerCount: 1,
                availableWorkers: [
                    AvailableWorkerToolDTO(
                        workerId: "research",
                        modelName: "worker_research",
                        functionId: "worker_kernel::dynamic_research",
                        functionRevision: 1,
                        workerVersion: "v1",
                        promoted: false,
                        projected: true,
                        selectionReason: "relevance",
                        relevanceScore: 1,
                        completedRuns: 1
                    )
                ]
            ),
            workers: includeRetiredFixture ? [retiredWorker, worker] : [worker],
            workerArchitecture: [
                WorkerArchitectureNodeDTO(
                    workerId: "research",
                    name: "Research",
                    description: "Recent research worker",
                    activeVersion: "v1",
                    health: "healthy",
                    modelExposure: "direct",
                    runnerKind: "command",
                    runnerModel: nil,
                    engineHooks: ["research_context"],
                    clientActions: [],
                    clientDeliveries: [],
                    triggerKinds: ["schedule"],
                    calls: [],
                    presentation: WorkerArchitecturePresentationDTO(
                        suiteId: "research",
                        componentRole: "search",
                        primary: true
                    ),
                    provenance: []
                ),
                WorkerArchitectureNodeDTO(
                    workerId: "research-coordinator",
                    name: "Research Coordinator",
                    description: "Coordinates research",
                    activeVersion: "v1",
                    health: "healthy",
                    modelExposure: "direct",
                    runnerKind: "agent",
                    runnerModel: "test-model",
                    engineHooks: [],
                    clientActions: [],
                    clientDeliveries: [],
                    triggerKinds: [],
                    calls: [
                        WorkerArchitectureEdgeDTO(
                            kind: "agent_tool",
                            label: "Research",
                            targetWorkerId: "research",
                            responseOwner: nil
                        ),
                    ],
                    presentation: WorkerArchitecturePresentationDTO(
                        suiteId: "research",
                        componentRole: "coordinator",
                        primary: true
                    ),
                    provenance: []
                ),
            ]
        )
    }

    func workers(includeRetired: Bool) async throws -> WorkerListResultDTO {
        WorkerListResultDTO(workers: [worker], stopAll: false)
    }

    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO {
        WorkerInspectResultDTO(
            worker: worker,
            bundle: [
                "inputSchema": AnyCodable(["type": "object"]),
                "provenance": AnyCodable(["source": "test"]),
            ],
            versions: [
                WorkerVersionDTO(
                    version: "v1",
                    contentHash: "v1",
                    createdAt: "2026-07-19T12:00:00Z"
                ),
            ],
            triggers: [],
            audit: [],
            versionDirectory: "/test/workers/research/versions/v1"
        )
    }

    func workerRuns(
        workerId: String?,
        originSessionId: String?,
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerRunsResultDTO {
        runLimits.append(limit)
        runOffsets.append(offset)
        if pagedActivity, workerId == nil {
            if offset == nil {
                return WorkerRunsResultDTO(
                    runs: [invocation(id: "prior-run", output: ["prior": true])],
                    truncated: true,
                    nextOffset: 1
                )
            }
            return WorkerRunsResultDTO(
                runs: [invocation(id: "older-run", output: ["older": true])],
                truncated: false,
                nextOffset: nil
            )
        }
        return WorkerRunsResultDTO(runs: [invocation(id: "prior-run", output: ["prior": true])])
    }

    func workerInbox(
        workerId: String?,
        limit: UInt64,
        offset: UInt64?,
        attentionOnly: Bool
    ) async throws -> WorkerInboxResultDTO {
        inboxLimits.append(limit)
        inboxAttentionFilters.append(attentionOnly)
        return WorkerInboxResultDTO(items: [
            WorkerInboxItemDTO(
                inboxId: "inbox-1",
                invocationId: "prior-run",
                workerId: "research",
                severity: "info",
                result: AnyCodable(["prior": true]),
                contextAttached: false,
                createdAt: "2026-07-19T12:00:01Z",
                triggerKind: "schedule",
                hasInvocation: true,
                requiresAttention: true
            ),
        ])
    }

    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        invokedWorkerIds.append(workerId)
        lastInput = input.value as? [String: Any]
        return invocation(id: "new-run", output: ["accepted": true])
    }

    func enqueueWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWorker(workerId: workerId, input: input, idempotencyKey: idempotencyKey)
    }

    func cancelWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        cancelledInvocationIds.append(invocationId)
        return invocation(id: invocationId, output: ["cancelled": true])
    }

    func setWorkerEnabled(
        _ enabled: Bool,
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        self.enabled = enabled
        enabledMutations.append(enabled)
        return worker
    }

    func stopWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        stoppedWorkerIds.append(workerId)
        return worker
    }

    func rollbackWorker(
        workerId: String,
        version: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRollbackResultDTO {
        rollbackVersions.append(version)
        retired = false
        enabled = true
        return WorkerRollbackResultDTO(worker: worker, webhooks: [])
    }

    func retireWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        worker
    }

    func purgeWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerPurgeResultDTO {
        WorkerPurgeResultDTO(
            workerId: workerId,
            purged: true,
            archivePath: "/test/backups/research.tar.zst",
            archiveSha256: String(repeating: "a", count: 64)
        )
    }

    func setWorkersStopped(
        _ stopped: Bool,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerStopAllResultDTO {
        WorkerStopAllResultDTO(stopped: stopped)
    }

    func rotateWorkerWebhook(
        workerId: String,
        triggerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerWebhookCredentialDTO {
        WorkerWebhookCredentialDTO(triggerId: triggerId, path: "/hook", token: "redacted-test-token")
    }

    func ensureWorkerEventSubscriptions() async throws {
        workerSubscriptionCount += 1
    }

    private func invocation(id: String, output: [String: Any]) -> WorkerInvocationDTO {
        WorkerInvocationDTO(
            invocationId: id,
            workerId: "research",
            workerVersion: "v1",
            status: "completed",
            input: AnyCodable(["query": "Tron"]),
            output: AnyCodable(output),
            error: nil,
            idempotencyKey: "test-key",
            traceId: "trace-1",
            causalDepth: 0,
            triggerKind: "manual",
            originSessionId: nil,
            agentSessionId: nil,
            attemptCount: 1,
            createdAt: "2026-07-19T12:00:00Z",
            startedAt: nil,
            completedAt: "2026-07-19T12:00:01Z"
        )
    }
}
