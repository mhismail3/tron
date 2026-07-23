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

    @Test("Worker monitoring replays every topic from an explicit origin cursor")
    func monitoringUsesExplicitOriginCursors() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        let monitor = Task {
            await viewModel.monitor(repository: repository, connectionState: .connected)
        }
        try? await Task.sleep(for: .milliseconds(50))
        monitor.cancel()
        await monitor.value

        #expect(repository.polledCursors.count >= 2)
        #expect(Set(repository.polledCursors.prefix(2).map(\.topic)) == [
            "worker.lifecycle",
            "worker.invocations",
        ])
        #expect(repository.polledCursors.prefix(2).allSatisfy { $0.cursor == 0 })
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
}

@MainActor
private final class MockWorkerKernelRepository: WorkerKernelRepository {
    var enabled = true
    var retired = false
    var invokedWorkerIds: [String] = []
    var cancelledInvocationIds: [String] = []
    var stoppedWorkerIds: [String] = []
    var enabledMutations: [Bool] = []
    var rollbackVersions: [String] = []
    var lastInput: [String: Any]?
    var polledCursors: [(topic: String, cursor: UInt64)] = []
    var snapshotSessionIds: [String?] = []
    var runLimits: [UInt64] = []
    var inboxLimits: [UInt64] = []
    var inboxAttentionFilters: [Bool] = []
    var runOffsets: [UInt64?] = []
    var pagedActivity = false

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
            health: enabled ? "healthy" : "disabled",
            triggerCount: 1,
            updatedAt: "2026-07-19T12:00:00Z",
            presentation: nil
        )
    }

    func engineSurfaceSnapshot(
        sessionId: String?,
        relevanceQuery: String?
    ) async throws -> EngineIntrospectionSnapshotDTO {
        snapshotSessionIds.append(sessionId)
        return EngineIntrospectionSnapshotDTO(
            dispatchStopped: false,
            activeEngineHooks: [],
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
            workers: [worker]
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

    func pollWorkerEvents(
        topic: String,
        cursor: EngineStreamCursor
    ) async throws -> EngineStreamPage {
        polledCursors.append((topic, cursor.rawValue))
        return EngineStreamPage(events: [], hasMore: false, nextCursor: cursor.rawValue)
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
            agentSessionId: nil,
            attemptCount: 1,
            createdAt: "2026-07-19T12:00:00Z",
            startedAt: nil,
            completedAt: "2026-07-19T12:00:01Z"
        )
    }
}
