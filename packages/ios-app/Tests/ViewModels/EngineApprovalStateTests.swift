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

    private func approvalData(approvalId: String) -> EngineApprovalData {
        EngineApprovalData(
            invocationId: "engine-approval:\(approvalId)",
            params: EngineApprovalParams(
                action: "Run command",
                reason: "Requires approval",
                riskLevel: .high
            ),
            status: .pending,
            engineApprovalId: approvalId,
            engineFunctionId: "process::run"
        )
    }

    private func approvalRecord(
        approvalId: String,
        status: EngineApprovalStatus
    ) -> EngineApprovalRecordDTO {
        EngineApprovalRecordDTO(
            approvalId: approvalId,
            functionId: "process::run",
            payload: nil,
            actorId: nil,
            actorKind: nil,
            authorityScopes: nil,
            traceId: nil,
            parentInvocationId: "execute-wrapper",
            sessionId: "session-1",
            workspaceId: nil,
            idempotencyKey: "approval-key",
            status: status,
            decisionActorId: "user",
            decidedAt: "2026-05-29T21:00:00Z",
            createdAt: "2026-05-29T21:00:00Z",
            updatedAt: "2026-05-29T21:00:00Z"
        )
    }
}
