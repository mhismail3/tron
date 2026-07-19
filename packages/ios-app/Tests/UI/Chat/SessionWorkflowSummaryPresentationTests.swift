import XCTest
@testable import TronMobile

final class SessionWorkflowSummaryPresentationTests: XCTestCase {
    func testBranchMutationRequiresConnectionAndAnIdleSession() {
        XCTAssertTrue(BranchSessionMutationPolicy.canBranch(
            isConnected: true,
            isProcessing: false,
            isCreatingBranch: false
        ))
        XCTAssertFalse(BranchSessionMutationPolicy.canBranch(
            isConnected: false,
            isProcessing: false,
            isCreatingBranch: false
        ))
        XCTAssertFalse(BranchSessionMutationPolicy.canBranch(
            isConnected: true,
            isProcessing: true,
            isCreatingBranch: false
        ))
        XCTAssertFalse(BranchSessionMutationPolicy.canBranch(
            isConnected: true,
            isProcessing: false,
            isCreatingBranch: true
        ))
    }

    func testNamesTheThreeWorkflowsWithoutRenderingInternalIdentifiers() {
        let snapshot = SessionWorkflowSnapshotV1(
            schemaVersion: "tron.session_workflows.v1",
            contextRevision: ContextRevisionSnapshotV1(
                state: "succeeded",
                kind: "compact",
                reason: "Preserve decisions"
            ),
            branchLineage: BranchLineageSnapshotV1(isBranch: true),
            activeDelegations: [
                DelegationSnapshotV1(
                    state: "running",
                    objectiveSummary: "Check the branch boundary",
                    resultSummary: nil
                )
            ],
            recentDelegations: [],
            truncated: false
        )

        let presentation = SessionWorkflowSummaryPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.contextRevision?.title, "Context compacted")
        XCTAssertEqual(presentation.contextRevision?.detail, "Preserve decisions")
        XCTAssertEqual(presentation.branch?.title, "Branch session")
        XCTAssertEqual(presentation.delegation?.title, "1 active delegation")
        XCTAssertEqual(presentation.delegation?.detail, "Check the branch boundary")

        let renderedCopy = [
            presentation.contextRevision?.title,
            presentation.contextRevision?.detail,
            presentation.branch?.title,
            presentation.branch?.detail,
            presentation.delegation?.title,
            presentation.delegation?.detail
        ].compactMap { $0 }.joined(separator: " ")
        XCTAssertFalse(renderedCopy.contains("secret-"))
    }

    func testEmptyProjectionDoesNotMountAWorkflowCard() {
        let presentation = SessionWorkflowSummaryPresentation(
            snapshot: SessionWorkflowSnapshotV1(
                schemaVersion: "tron.session_workflows.v1",
                contextRevision: nil,
                branchLineage: BranchLineageSnapshotV1(isBranch: false),
                activeDelegations: [],
                recentDelegations: [],
                truncated: false
            )
        )

        XCTAssertFalse(presentation.hasContent)
    }

    func testRecentDelegationUsesResultAndSignalsTruncation() {
        let recent = DelegationSnapshotV1(
            state: "accepted",
            objectiveSummary: "Research options",
            resultSummary: "Two safe options found"
        )
        let presentation = SessionWorkflowSummaryPresentation(
            snapshot: SessionWorkflowSnapshotV1(
                schemaVersion: "tron.session_workflows.v1",
                contextRevision: nil,
                branchLineage: BranchLineageSnapshotV1(isBranch: false),
                activeDelegations: [],
                recentDelegations: [recent],
                truncated: true
            )
        )

        XCTAssertEqual(presentation.delegation?.title, "Delegation result accepted")
        XCTAssertEqual(
            presentation.delegation?.detail,
            "Two safe options found · More delegation history exists"
        )
    }
}
