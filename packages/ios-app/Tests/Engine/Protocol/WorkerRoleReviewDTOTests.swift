import Foundation
import Testing
@testable import TronMobile

@Suite("Worker Role Review DTO Tests")
struct WorkerRoleReviewDTOTests {
    @Test("Role review pages decode queue paging, durable history, and pinned provenance")
    func decodesCompleteRoleReviewPage() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "capability": "agent_role_review.v1",
            "reviewer": [
                "available": true,
                "workerId": "role-reviewer",
                "workerVersion": "review-v3",
            ],
            "items": [[
                "workerId": "legacy-agent",
                "name": "Legacy Agent",
                "description": "Agent runner awaiting an explicit decision",
                "targetVersion": "v7",
                "classification": "needs_role_review",
                "proposal": proposalJSON(status: "proposed"),
                "allowedActions": [[
                    "action": "inspect",
                    "allowed": true,
                ]],
            ]],
            "queueReturned": 1,
            "queueTotal": 202,
            "queueTruncated": true,
            "queueNextOffset": 100,
            "proposals": [proposalJSON(status: "proposed")],
            "returned": 1,
            "total": 51,
            "nextOffset": 50,
        ])

        let decoded = try JSONDecoder().decode(WorkerRoleReviewListDTO.self, from: data)
        let proposal = try #require(decoded.items.first?.proposal)

        #expect(decoded.capability == "agent_role_review.v1")
        #expect(decoded.reviewer.workerVersion == "review-v3")
        #expect(decoded.queueReturned == 1)
        #expect(decoded.queueTotal == 202)
        #expect(decoded.queueTruncated)
        #expect(decoded.queueNextOffset == 100)
        #expect(decoded.total == 51)
        #expect(decoded.nextOffset == 50)
        #expect(proposal.reviewerInvocationId == "worker_run_reviewer_1")
        #expect(proposal.action("apply")?.allowed == true)

        let declaration = WorkerAgentRoleReviewPresentation.declaration(proposal.agentRole)
        #expect(declaration.decision == .enabled)
        #expect(declaration.title == "Reusable role enabled")
        #expect(declaration.fields.first { $0.label == "Display name" }?.value == "Specialist")
        #expect(declaration.fields.first { $0.label == "Tool ceiling" }?.value == "filesystem_read, result_read")
    }

    @Test("Older role review pages decode read-only defaults without inventing actions")
    func toleratesOmittedAdditiveFields() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "capability": "agent_role_review.v1",
            "reviewer": [
                "available": false,
                "repairRequirement": "Activate a healthy reviewer.",
            ],
            "items": [[
                "workerId": "legacy-agent",
                "name": "Legacy Agent",
                "description": "Needs review",
                "targetVersion": "v1",
                "classification": "needs_role_review",
            ]],
        ])

        let decoded = try JSONDecoder().decode(WorkerRoleReviewListDTO.self, from: data)

        #expect(!decoded.reviewer.available)
        #expect(decoded.reviewer.repairRequirement == "Activate a healthy reviewer.")
        #expect(decoded.items.first?.allowedActions.isEmpty == true)
        #expect(decoded.queueReturned == 1)
        #expect(decoded.queueTotal == 1)
        #expect(!decoded.queueTruncated)
        #expect(decoded.queueNextOffset == nil)
        #expect(decoded.proposals.isEmpty)
        #expect(decoded.nextOffset == nil)
    }

    @Test("Disabled declarations remain an explicit reviewed decision")
    func presentsDisabledDeclaration() {
        let declaration = WorkerAgentRoleReviewPresentation.declaration(
            AnyCodable(["status": "disabled"])
        )

        #expect(declaration.decision == .disabled)
        #expect(declaration.title == "Reusable role disabled")
        #expect(declaration.fields.isEmpty)
    }

    private func proposalJSON(status: String) -> [String: Any] {
        [
            "proposalId": "role_proposal_1",
            "schemaVersion": 1,
            "proposalHash": "sha256:proposal",
            "targetWorkerId": "legacy-agent",
            "targetWorkerVersion": "v7",
            "targetContentHash": "sha256:target",
            "reviewerWorkerId": "role-reviewer",
            "reviewerWorkerVersion": "review-v3",
            "reviewerInvocationId": "worker_run_reviewer_1",
            "status": status,
            "agentRole": [
                "status": "enabled",
                "displayName": "Specialist",
                "summary": "Handles one bounded specialty.",
                "discoverable": true,
                "collaborationInstructions": "Work within the assigned specialty.",
                "defaultModel": "gpt-5.6-sol",
                "defaultReasoningLevel": "high",
                "toolCeiling": ["filesystem_read", "result_read"],
                "limits": [
                    "maxAssignmentTurns": 24,
                    "maxQueuedAssignments": 4,
                ],
                "resultMode": "natural",
            ],
            "rationale": "The worker has a stable reusable specialty.",
            "createdAt": "2026-08-11T08:00:00Z",
            "updatedAt": "2026-08-11T08:01:00Z",
            "allowedActions": [
                ["action": "inspect", "allowed": true],
                ["action": "apply", "allowed": true],
                ["action": "reject", "allowed": true],
            ],
        ]
    }
}
