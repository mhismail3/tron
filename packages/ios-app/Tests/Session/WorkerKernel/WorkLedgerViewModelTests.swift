import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Work Ledger Experience Tests")
struct WorkLedgerViewModelTests {
    @Test("Only the supported immutable presentation contract opens the native experience")
    func experienceRoutingFallsBackForUnknownContracts() {
        #expect(WorkerExperienceRoute.resolve(Self.worker(contractVersion: 1)) == .workLedger)
        #expect(WorkerExperienceRoute.resolve(Self.worker(contractVersion: 2)) == .genericConsole)
        #expect(WorkerExperienceRoute.resolve(Self.worker(experienceId: "research-suite")) == .genericConsole)
        #expect(WorkerExperienceRoute.resolve(Self.worker(experienceId: "general-delegate")) == .genericConsole)
        #expect(WorkerExperienceRoute.resolve(Self.worker(primary: false)) == .genericConsole)
    }

    @Test("Snapshot decoding preserves durable goals, questions, decisions, and activity")
    func snapshotDecoding() throws {
        let snapshot = try WorkLedgerContract.decodeSnapshot(AnyCodable(Self.snapshotOutput))

        #expect(snapshot.goals.map(\.id) == ["goal-1"])
        #expect(snapshot.goals.first?.status == "active")
        #expect(snapshot.questions.first?.goalId == "goal-1")
        #expect(snapshot.questions.first?.answer == nil)
        #expect(snapshot.decisions.first?.rationale == "Keeps the kernel small")
        #expect(snapshot.recentHistory.first?.action == "create_goal")
        #expect(snapshot.activeGoalCount == 1)
        #expect(snapshot.openQuestionCount == 1)
        #expect(snapshot.decisionCount == 1)
    }

    @Test("A worker-declared typed failure remains visible instead of replacing state")
    func typedFailureIsRejected() {
        #expect(throws: WorkLedgerContractError.workerFailure("title is required")) {
            try WorkLedgerContract.validateMutation(
                AnyCodable(["ok": false, "action": "create_goal", "error": "title is required"])
            )
        }
    }

    @Test("Refresh uses one snapshot invocation and mutations use the flat worker contract")
    func viewModelUsesSnapshotAndFlatMutationContract() async {
        let repository = WorkLedgerMockRepository()
        let viewModel = WorkLedgerViewModel()

        await viewModel.refresh(
            workerId: "work-ledger",
            repository: repository,
            connectionState: .connected
        )

        #expect(repository.inputs.count == 1)
        #expect(repository.inputs[0]["action"] as? String == "snapshot")
        #expect(repository.inputs[0]["history_limit"] as? Int == 50)
        #expect(viewModel.snapshot.activeGoalCount == 1)

        let succeeded = await viewModel.createGoal(
            title: "Restore workers",
            description: "Prove each capability through real use",
            workerId: "work-ledger",
            repository: repository,
            connectionState: .connected
        )

        #expect(succeeded)
        #expect(repository.inputs.count == 3)
        #expect(repository.inputs[1]["action"] as? String == "create_goal")
        #expect(repository.inputs[1]["title"] as? String == "Restore workers")
        #expect(repository.inputs[1]["description"] as? String == "Prove each capability through real use")
        #expect(repository.inputs[1]["params"] == nil)
        #expect(repository.inputs[2]["action"] as? String == "snapshot")
        #expect(viewModel.lastError == nil)
    }

    private static func worker(
        experienceId: String = "work-ledger",
        contractVersion: UInt32 = 1,
        primary: Bool = true
    ) -> WorkerSummaryDTO {
        WorkerSummaryDTO(
            workerId: "work-ledger",
            name: "Work Ledger",
            description: "Durable goals and questions",
            toolName: "worker_work_ledger",
            runnerKind: "command",
            activeVersion: "v1",
            enabled: true,
            retired: false,
            health: "healthy",
            triggerCount: 1,
            updatedAt: "2026-07-22T09:00:00Z",
            presentation: WorkerPresentationDTO(
                experienceId: experienceId,
                contractVersion: contractVersion,
                suiteId: "work-ledger",
                componentRole: "primary",
                primary: primary
            )
        )
    }

    fileprivate static let snapshotOutput: [String: Any] = [
        "ok": true,
        "action": "snapshot",
        "snapshot": [
            "counts": [
                "goals": ["active": 1, "completed": 0, "cancelled": 0],
                "questions": ["open": 1, "answered": 0, "resolved": 0],
                "decisions": ["total": 1],
                "history": ["total": 1],
            ],
            "goals": [[
                "id": "goal-1",
                "title": "Restore workers",
                "description": "Prove capabilities through use",
                "status": "active",
                "created_at": "2026-07-22T09:00:00Z",
                "updated_at": "2026-07-22T09:00:00Z",
                "completed_at": NSNull(),
                "cancelled_at": NSNull(),
                "cancel_reason": NSNull(),
            ]],
            "questions": [[
                "id": "question-1",
                "goal_id": "goal-1",
                "text": "What should be restored next?",
                "status": "open",
                "answer": NSNull(),
                "created_at": "2026-07-22T09:01:00Z",
                "updated_at": "2026-07-22T09:01:00Z",
                "answered_at": NSNull(),
                "resolved_at": NSNull(),
            ]],
            "decisions": [[
                "id": "decision-1",
                "goal_id": "goal-1",
                "question_id": "question-1",
                "title": "Use workers",
                "rationale": "Keeps the kernel small",
                "created_at": "2026-07-22T09:02:00Z",
            ]],
            "recent_history": [[
                "id": 1,
                "ts": "2026-07-22T09:00:00Z",
                "entity_type": "goal",
                "entity_id": "goal-1",
                "action": "create_goal",
                "details": [:],
            ]],
        ],
    ]
}

@MainActor
private final class WorkLedgerMockRepository: WorkerKernelRepository {
    var inputs: [[String: Any]] = []

    func invokeWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        let input = input.dictionaryValue ?? [:]
        inputs.append(input)
        let action = input["action"] as? String
        let output: [String: Any] = action == "snapshot"
            ? WorkLedgerViewModelTests.snapshotOutput
            : ["ok": true, "action": action ?? "unknown"]
        return invocation(output: output)
    }

    func enqueueWorker(
        workerId: String,
        input: AnyCodable,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        try await invokeWorker(workerId: workerId, input: input, idempotencyKey: idempotencyKey)
    }

    func engineSurfaceSnapshot(
        sessionId: String?,
        relevanceQuery: String?
    ) async throws -> EngineIntrospectionSnapshotDTO {
        throw EngineConnectionError.invalidResponse
    }

    func workers(includeRetired: Bool) async throws -> WorkerListResultDTO {
        WorkerListResultDTO(workers: [], stopAll: false)
    }

    func inspectWorker(_ workerId: String) async throws -> WorkerInspectResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func workerRuns(
        workerId: String?,
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerRunsResultDTO {
        WorkerRunsResultDTO(runs: [])
    }

    func workerInbox(
        workerId: String?,
        limit: UInt64,
        offset: UInt64?
    ) async throws -> WorkerInboxResultDTO {
        WorkerInboxResultDTO(items: [])
    }

    func cancelWorkerInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        invocation(output: ["ok": true])
    }

    func setWorkerEnabled(
        _ enabled: Bool,
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        throw EngineConnectionError.invalidResponse
    }

    func stopWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        throw EngineConnectionError.invalidResponse
    }

    func rollbackWorker(
        workerId: String,
        version: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerRollbackResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func retireWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        throw EngineConnectionError.invalidResponse
    }

    func purgeWorker(
        workerId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> WorkerPurgeResultDTO {
        throw EngineConnectionError.invalidResponse
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
        throw EngineConnectionError.invalidResponse
    }

    func pollWorkerEvents(
        topic: String,
        cursor: EngineStreamCursor
    ) async throws -> EngineStreamPage {
        EngineStreamPage(events: [], hasMore: false, nextCursor: cursor.rawValue)
    }

    private func invocation(output: [String: Any]) -> WorkerInvocationDTO {
        WorkerInvocationDTO(
            invocationId: "run-\(inputs.count)",
            workerId: "work-ledger",
            workerVersion: "v1",
            status: "completed",
            input: AnyCodable(inputs.last ?? [:]),
            output: AnyCodable(output),
            error: nil,
            idempotencyKey: "test",
            traceId: "trace",
            causalDepth: 0,
            triggerKind: "manual",
            agentSessionId: nil,
            attemptCount: 1,
            createdAt: "2026-07-22T09:00:00Z",
            startedAt: "2026-07-22T09:00:00Z",
            completedAt: "2026-07-22T09:00:01Z"
        )
    }
}
