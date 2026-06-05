import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("WorkDashboardState")
struct WorkDashboardStateTests {
    @Test("refresh reads the server-owned Work snapshot projection")
    func refreshReadsWorkSnapshot() async throws {
        let client = FakeWorkSnapshotClient()
        client.snapshot = Self.snapshot(
            workers: [
                Self.worker(
                    workerId: "subagent:review-1",
                    label: "Review worker",
                    health: "healthy"
                ),
            ],
            milestones: [
                WorkMilestoneDTO(
                    kind: "invocation",
                    status: "completed",
                    functionId: "demo::echo",
                    workerId: "subagent:review-1",
                    invocationId: "inv-1",
                    traceId: "trace-1",
                    auditRef: WorkAuditRefDTO(kind: "invocation", id: "inv-1", traceId: "trace-1", catalogRevision: nil)
                ),
            ]
        )
        let state = WorkDashboardState(client: client)

        await state.refresh(sessionId: "session-1", workspaceId: "workspace-1")

        #expect(client.requests == [
            WorkSnapshotRequest(sessionId: "session-1", workspaceId: "workspace-1", limit: 12),
        ])
        #expect(state.loadState == .loaded)
        #expect(state.snapshot?.workers.first?.label == "Review worker")
        #expect(state.recentMilestonesForWorker(client.snapshot.workers[0]).first?.invocationId == "inv-1")
    }

    @Test("guardrail prompts become visible blocked work")
    func guardrailPromptsBecomeBlockedWork() async throws {
        let client = FakeWorkSnapshotClient()
        client.snapshot = Self.snapshot(
            activeWork: [
                WorkActiveItemDTO(kind: "approval_wait", status: "waiting", functionId: "demo::write", approvalId: "approval-1", traceId: "trace-approval"),
            ],
            guardrails: [
                WorkGuardrailDTO(
                    kind: "approval_prompt",
                    status: "blocked",
                    functionId: "demo::write",
                    approvalId: "approval-1",
                    traceId: "trace-approval",
                    risk: "High",
                    summary: "Testing-mode approval prompt is waiting for a decision.",
                    auditRef: WorkAuditRefDTO(kind: "approval", id: "approval-1", traceId: "trace-approval", catalogRevision: nil)
                ),
            ]
        )
        let state = WorkDashboardState(client: client)

        await state.refresh()

        #expect(state.hasBlockedWork)
        #expect(state.snapshot?.guardrails.first?.summary == "Testing-mode approval prompt is waiting for a decision.")
    }

    @Test("refresh failure stays explicit")
    func refreshFailureStaysExplicit() async {
        let client = FakeWorkSnapshotClient()
        client.error = EngineConnectionError.notConnected
        let state = WorkDashboardState(client: client)

        await state.refresh()

        guard case .failed(let message) = state.loadState else {
            Issue.record("Expected failed state")
            return
        }
        #expect(!message.isEmpty)
        #expect(state.snapshot == nil)
    }

    static func snapshot(
        activeWork: [WorkActiveItemDTO] = [],
        workers: [WorkWorkerDTO] = [],
        milestones: [WorkMilestoneDTO] = [],
        guardrails: [WorkGuardrailDTO] = []
    ) -> WorkSnapshotDTO {
        WorkSnapshotDTO(
            autonomy: WorkAutonomyDTO(
                mode: "independent",
                approvalPromptMode: "disabled",
                interactiveApprovalPrompts: false,
                statusLabel: "Runs independently",
                summary: "Approval-required autonomous work is audited and auto-decided unless a guardrail blocks it."
            ),
            activeWork: activeWork,
            workers: workers,
            recentMilestones: milestones,
            guardrails: guardrails,
            auditRefs: [WorkAuditRefDTO(kind: "catalog", id: nil, traceId: nil, catalogRevision: 42)],
            scope: WorkScopeDTO(sessionId: nil, workspaceId: nil)
        )
    }

    private static func worker(workerId: String, label: String, health: String) -> WorkWorkerDTO {
        WorkWorkerDTO(
            workerId: workerId,
            label: label,
            status: "Running",
            health: health,
            abilityCount: 1,
            abilities: [
                WorkAbilityDTO(
                    functionId: "agent::spawn_subagent",
                    label: "Delegated agent work",
                    risk: "Medium",
                    effect: "ExternalSideEffect",
                    health: "Healthy"
                ),
            ],
            namespaceClaims: ["agent"],
            workerType: "agent",
            runId: "review-1",
            elapsedMs: 1200,
            auditRef: WorkAuditRefDTO(kind: "subagent", id: "review-1", traceId: nil, catalogRevision: nil)
        )
    }
}

@MainActor
private final class FakeWorkSnapshotClient: AgentWorkSnapshotClient {
    var snapshot = WorkDashboardStateTests.snapshot()
    var requests: [WorkSnapshotRequest] = []
    var error: Error?

    func workSnapshot(sessionId: String?, workspaceId: String?, limit: Int) async throws -> WorkSnapshotDTO {
        requests.append(WorkSnapshotRequest(sessionId: sessionId, workspaceId: workspaceId, limit: limit))
        if let error {
            throw error
        }
        return snapshot
    }
}

private struct WorkSnapshotRequest: Equatable {
    let sessionId: String?
    let workspaceId: String?
    let limit: Int
}
