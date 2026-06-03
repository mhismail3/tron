import XCTest
@testable import TronMobile

@MainActor
final class EngineApprovalStateTests: XCTestCase {
    func testTerminalApprovalClearsMatchingOpenSheet() {
        let state = EngineApprovalState()
        state.currentData = approvalData(approvalId: "approval-1")
        state.pendingSubmission = PendingEngineApprovalSubmission(
            action: "Run command",
            decision: EngineApprovalUserDecision.approved.rawValue,
            note: nil,
            engineApprovalId: "approval-1",
            engineFunctionId: "process::run"
        )
        state.showSheet = true

        state.clearSheetIfShowingApproval("approval-1")

        XCTAssertFalse(state.showSheet)
        XCTAssertNil(state.currentData)
        XCTAssertNil(state.pendingSubmission)
    }

    func testTerminalApprovalDoesNotClearDifferentOpenSheet() {
        let state = EngineApprovalState()
        state.currentData = approvalData(approvalId: "approval-1")
        state.pendingSubmission = PendingEngineApprovalSubmission(
            action: "Run command",
            decision: EngineApprovalUserDecision.approved.rawValue,
            note: nil,
            engineApprovalId: "approval-1",
            engineFunctionId: "process::run"
        )
        state.showSheet = true

        state.clearSheetIfShowingApproval("approval-2")

        XCTAssertTrue(state.showSheet)
        XCTAssertEqual(state.currentData?.engineApprovalId, "approval-1")
        XCTAssertNotNil(state.pendingSubmission)
    }

    func testResolvedApprovalEventClearsMatchingChatSheetState() {
        let viewModel = ChatViewModel(
            engineClient: EngineClient(serverURL: URL(string: "ws://localhost:0")!),
            sessionId: "session-1"
        )
        let pending = approvalData(approvalId: "approval-1")
        viewModel.messages = [ChatMessage(role: .assistant, content: .engineApproval(pending))]
        viewModel.engineApprovalState.currentData = pending
        viewModel.engineApprovalState.showSheet = true
        viewModel.engineApprovalState.pendingSubmission = PendingEngineApprovalSubmission(
            action: "Run command",
            decision: EngineApprovalUserDecision.approved.rawValue,
            note: nil,
            engineApprovalId: "approval-1",
            engineFunctionId: "process::run"
        )

        viewModel.handleApprovalResolved(
            ApprovalResolvedPlugin.Result(
                approval: approvalRecord(approvalId: "approval-1", status: .executed),
                child: nil
            )
        )

        XCTAssertFalse(viewModel.engineApprovalState.showSheet)
        XCTAssertNil(viewModel.engineApprovalState.currentData)
        XCTAssertNil(viewModel.engineApprovalState.pendingSubmission)
        if case .engineApproval(let data) = viewModel.messages.first?.content {
            XCTAssertEqual(data.status, .approved)
        } else {
            XCTFail("expected engine approval chip")
        }
    }

    func testPendingApprovalEventCreatesChipAndOpensSheet() {
        let viewModel = ChatViewModel(
            engineClient: EngineClient(serverURL: URL(string: "ws://localhost:0")!),
            sessionId: "session-1"
        )

        viewModel.handleApprovalPending(
            ApprovalPendingPlugin.Result(
                approval: approvalRecord(approvalId: "approval-1", status: .pending)
            )
        )

        XCTAssertTrue(viewModel.engineApprovalState.showSheet)
        XCTAssertEqual(viewModel.engineApprovalState.currentData?.engineApprovalId, "approval-1")
        XCTAssertEqual(viewModel.messages.count, 1)
        if case .engineApproval(let data) = viewModel.messages.first?.content {
            XCTAssertEqual(data.status, .pending)
            XCTAssertEqual(data.engineApprovalId, "approval-1")
            XCTAssertEqual(data.engineFunctionId, "process::run")
        } else {
            XCTFail("expected pending engine approval chip")
        }
    }

    func testPendingApprovalProjectsServerConsequenceMetadataForSheet() {
        let viewModel = ChatViewModel(
            engineClient: EngineClient(serverURL: URL(string: "ws://localhost:0")!),
            sessionId: "session-1"
        )

        viewModel.handleApprovalPending(
            ApprovalPendingPlugin.Result(
                approval: approvalRecord(
                    approvalId: "approval-1",
                    status: .pending,
                    authorityGrantId: "grant:agent",
                    authorityScopes: ["process.run", "filesystem.write"],
                    targetMetadata: targetMetadata()
                )
            )
        )

        guard let data = viewModel.engineApprovalState.currentData else {
            XCTFail("expected approval sheet data")
            return
        }
        XCTAssertEqual(data.params.riskLevel, .critical)
        XCTAssertEqual(data.authorityGrantId, "grant:agent")
        XCTAssertEqual(data.authorityScopes, ["process.run", "filesystem.write"])
        XCTAssertEqual(data.idempotencyKey, "approval-key")
        XCTAssertEqual(data.targetMetadata?.effectClass, "IrreversibleSideEffect")

        let flattenedRows = data.consequenceSections.flatMap { section in
            section.rows.map { "\(section.title):\($0.label)=\($0.value)" }
        }
        XCTAssertTrue(flattenedRows.contains("Consequence:Effect=Irreversible Side Effect"))
        XCTAssertTrue(flattenedRows.contains("Consequence:Risk=Critical"))
        XCTAssertTrue(flattenedRows.contains("Consequence:Approval=Required"))
        XCTAssertTrue(flattenedRows.contains("Authority:Grant=grant:agent"))
        XCTAssertTrue(flattenedRows.contains("Authority:Caller scopes=process.run, filesystem.write"))
        XCTAssertTrue(flattenedRows.contains("Authority:Required scopes=process.run"))
        XCTAssertTrue(flattenedRows.contains("Idempotency:Key=approval-key"))
        XCTAssertTrue(flattenedRows.contains("Idempotency:Contract=Caller / Session / Return Previous / Engine Ledger"))
        XCTAssertTrue(flattenedRows.contains("Lease:Resource=worktree: worktree:{sessionId}"))
        XCTAssertTrue(flattenedRows.contains("Lease:Failure=Fail Closed"))
        XCTAssertTrue(flattenedRows.contains("Compensation:Kind=Manual Only"))
        XCTAssertTrue(flattenedRows.contains("Compensation:Notes=manual recovery required"))
    }

    func testApprovalSubmissionWaitsForServerResolveBeforeDecidedChip() {
        let viewModel = ChatViewModel(
            engineClient: EngineClient(serverURL: URL(string: "ws://localhost:0")!),
            sessionId: "session-1"
        )
        let pending = approvalData(approvalId: "approval-1")
        viewModel.messages = [ChatMessage(role: .assistant, content: .engineApproval(pending))]
        viewModel.engineApprovalState.currentData = pending
        viewModel.engineApprovalState.showSheet = true
        viewModel.connectionState = .connected

        viewModel.prepareEngineApprovalSubmission(.approved, note: "ok")

        XCTAssertFalse(viewModel.engineApprovalState.showSheet)
        XCTAssertEqual(viewModel.engineApprovalState.pendingSubmission?.engineApprovalId, "approval-1")
        if case .engineApproval(let data) = viewModel.messages.first?.content {
            XCTAssertEqual(data.status, .resolving)
            XCTAssertNil(data.decision)
            XCTAssertNil(data.result)
            XCTAssertEqual(data.note, "ok")
        } else {
            XCTFail("expected resolving engine approval chip")
        }
    }

    func testOfflineApprovalSubmissionFailsClosedBeforeResolvingChip() {
        let viewModel = ChatViewModel(
            engineClient: EngineClient(serverURL: URL(string: "ws://localhost:0")!),
            sessionId: "session-1"
        )
        let pending = approvalData(approvalId: "approval-1")
        viewModel.messages = [ChatMessage(role: .assistant, content: .engineApproval(pending))]
        viewModel.engineApprovalState.currentData = pending
        viewModel.engineApprovalState.showSheet = true

        viewModel.prepareEngineApprovalSubmission(.approved, note: "ok")

        XCTAssertTrue(viewModel.engineApprovalState.showSheet)
        XCTAssertNil(viewModel.engineApprovalState.pendingSubmission)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Approval decisions are read-only while disconnected; reconnect before resolving approval."
        )
        if case .engineApproval(let data) = viewModel.messages.first?.content {
            XCTAssertEqual(data.status, .pending)
            XCTAssertNil(data.decision)
            XCTAssertNil(data.result)
            XCTAssertNil(data.note)
        } else {
            XCTFail("expected pending engine approval chip")
        }
    }

    func testResolvingApprovalCannotBeSubmittedAgain() {
        let viewModel = ChatViewModel(
            engineClient: EngineClient(serverURL: URL(string: "ws://localhost:0")!),
            sessionId: "session-1"
        )
        let resolving = approvalData(approvalId: "approval-1", status: .resolving)
        viewModel.messages = [ChatMessage(role: .assistant, content: .engineApproval(resolving))]
        viewModel.engineApprovalState.currentData = resolving
        viewModel.engineApprovalState.showSheet = true

        viewModel.prepareEngineApprovalSubmission(.denied, note: nil)

        XCTAssertFalse(viewModel.engineApprovalState.showSheet)
        XCTAssertNil(viewModel.engineApprovalState.currentData)
        XCTAssertNil(viewModel.engineApprovalState.pendingSubmission)
        if case .engineApproval(let data) = viewModel.messages.first?.content {
            XCTAssertEqual(data.status, .resolving)
            XCTAssertNil(data.decision)
        } else {
            XCTFail("expected resolving engine approval chip")
        }
    }

    private func approvalData(
        approvalId: String,
        status: EngineApprovalChipStatus = .pending
    ) -> EngineApprovalData {
        EngineApprovalData(
            invocationId: "engine-approval:\(approvalId)",
            params: EngineApprovalParams(
                action: "Run command",
                reason: "Requires approval",
                riskLevel: .high
            ),
            status: status,
            engineApprovalId: approvalId,
            engineFunctionId: "process::run"
        )
    }

    private func approvalRecord(
        approvalId: String,
        status: EngineApprovalStatus,
        authorityGrantId: String? = nil,
        authorityScopes: [String]? = nil,
        targetMetadata: EngineApprovalTargetMetadataDTO? = nil
    ) -> EngineApprovalRecordDTO {
        EngineApprovalRecordDTO(
            approvalId: approvalId,
            functionId: "process::run",
            payload: nil,
            actorId: nil,
            actorKind: nil,
            authorityGrantId: authorityGrantId,
            authorityScopes: authorityScopes,
            traceId: nil,
            parentInvocationId: "execute-wrapper",
            sessionId: "session-1",
            workspaceId: nil,
            idempotencyKey: "approval-key",
            targetMetadata: targetMetadata,
            status: status,
            decisionActorId: "user",
            decidedAt: "2026-05-29T21:00:00Z",
            createdAt: "2026-05-29T21:00:00Z",
            updatedAt: "2026-05-29T21:00:00Z"
        )
    }

    private func targetMetadata() -> EngineApprovalTargetMetadataDTO {
        EngineApprovalTargetMetadataDTO(
            effectClass: "IrreversibleSideEffect",
            riskLevel: "Critical",
            requiredAuthority: EngineApprovalAuthorityRequirementDTO(
                scopes: ["process.run"],
                approvalRequired: true
            ),
            idempotency: EngineApprovalIdempotencyContractDTO(
                keySource: "Caller",
                dedupeScope: "Session",
                replayBehavior: "ReturnPrevious",
                ledgerKind: "EngineLedger"
            ),
            resourceLease: EngineApprovalResourceLeaseRequirementDTO(
                resolverId: "payload_template",
                resourceKind: "worktree",
                resourceIdTemplate: "worktree:{sessionId}",
                ttlMs: 60000,
                exclusive: true,
                streamTopic: "resource.leases",
                failureBehavior: "failClosed"
            ),
            compensation: EngineApprovalCompensationContractDTO(
                kind: "manualOnly",
                notes: "manual recovery required"
            )
        )
    }
}
