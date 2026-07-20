import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Worker Console View Model Tests")
struct WorkerConsoleViewModelTests {
    @Test("Refresh, inspect, typed invoke, and disable use the worker kernel repository")
    func operationalFlowUsesWorkerKernelRepository() async {
        let repository = MockWorkerKernelRepository()
        let viewModel = WorkerConsoleViewModel()

        await viewModel.refresh(repository: repository, connectionState: .connected)
        #expect(viewModel.workers.map(\.workerId) == ["research"])
        #expect(viewModel.healthyCount == 1)

        await viewModel.select("research", repository: repository)
        #expect(viewModel.inspection?.versions.first?.version == "v1")
        #expect(viewModel.runs.first?.invocationId == "prior-run")
        #expect(viewModel.inbox.first?.inboxId == "inbox-1")

        viewModel.invocationInput = #"{"query":"Tron"}"#
        await viewModel.invoke(repository: repository, connectionState: .connected)
        #expect(repository.invokedWorkerIds == ["research"])
        #expect(repository.lastInput?["query"] as? String == "Tron")
        #expect(viewModel.invocationResult?.contains("accepted") == true)

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
}

@MainActor
private final class MockWorkerKernelRepository: WorkerKernelRepository {
    var enabled = true
    var retired = false
    var invokedWorkerIds: [String] = []
    var enabledMutations: [Bool] = []
    var rollbackVersions: [String] = []
    var lastInput: [String: Any]?

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
            updatedAt: "2026-07-19T12:00:00Z"
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

    func workerRuns(workerId: String?, limit: UInt64) async throws -> WorkerRunsResultDTO {
        WorkerRunsResultDTO(runs: [invocation(id: "prior-run", output: ["prior": true])])
    }

    func workerInbox(workerId: String?, limit: UInt64) async throws -> WorkerInboxResultDTO {
        WorkerInboxResultDTO(items: [
            WorkerInboxItemDTO(
                inboxId: "inbox-1",
                invocationId: "prior-run",
                workerId: "research",
                severity: "info",
                result: AnyCodable(["prior": true]),
                seen: false,
                createdAt: "2026-07-19T12:00:01Z"
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

    func setWorkerEnabled(
        _ enabled: Bool,
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        self.enabled = enabled
        enabledMutations.append(enabled)
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
        WorkerPurgeResultDTO(workerId: workerId, purged: true)
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
        cursor: EngineStreamCursor?
    ) async throws -> EngineStreamPage {
        EngineStreamPage(events: [], hasMore: false, nextCursor: cursor?.rawValue)
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
            attemptCount: 1,
            createdAt: "2026-07-19T12:00:00Z",
            startedAt: nil,
            completedAt: "2026-07-19T12:00:01Z"
        )
    }
}
