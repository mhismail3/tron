import Foundation
import Testing
@testable import TronMobile

@Suite("Worker Kernel DTO Tests")
struct WorkerKernelDTOTests {
    @Test("Inspection decodes the complete operational worker projection")
    func inspectionDecodesOperationalProjection() throws {
        let json = #"""
        {
          "worker": {
            "workerId": "recent-research",
            "name": "Recent Research",
            "description": "Researches the recent web",
            "toolName": "recent_research",
            "runnerKind": "command",
            "activeVersion": "abc123",
            "enabled": true,
            "retired": false,
            "health": "healthy",
            "triggerCount": 2,
            "presentation": {
              "experienceId": "research-suite",
              "contractVersion": 1,
              "suiteId": "research",
              "componentRole": "coordinator",
              "primary": true
            },
            "updatedAt": "2026-07-19T12:00:00Z"
          },
          "bundle": {
            "inputSchema": {"type": "object"},
            "provenance": {"source": "https://example.test/upstream"}
          },
          "versions": [{
            "version": "abc123",
            "contentHash": "abc123",
            "createdAt": "2026-07-19T12:00:00Z"
          }],
          "triggers": [{
            "triggerId": "daily",
            "kind": "schedule",
            "configuration": {"intervalSeconds": 86400},
            "tokenConfigured": false,
            "nextRunAt": "2026-07-20T12:00:00Z",
            "streamCursor": 0,
            "enabled": true
          }],
          "audit": [{
            "auditId": "audit-1",
            "workerId": "recent-research",
            "action": "activated",
            "details": {"version": "abc123"},
            "createdAt": "2026-07-19T12:00:00Z"
          }],
          "versionDirectory": "/profile/workers/recent-research/versions/abc123",
          "futureField": "ignored"
        }
        """#

        let inspection = try JSONDecoder().decode(
            WorkerInspectResultDTO.self,
            from: Data(json.utf8)
        )

        #expect(inspection.worker.toolName == "recent_research")
        #expect(inspection.worker.presentation?.experienceId == "research-suite")
        #expect(inspection.worker.presentation?.suiteId == "research")
        #expect(inspection.worker.presentation?.primary == true)
        #expect(inspection.versions.first?.contentHash == "abc123")
        #expect(inspection.triggers.first?.kind == "schedule")
        #expect(inspection.audit.first?.action == "activated")
        #expect(inspection.bundle["provenance"] != nil)
    }

    @Test("Durable runs and inbox preserve typed result values")
    func runsAndInboxPreserveTypedValues() throws {
        let runJSON = #"""
        {"runs":[{
          "invocationId":"run-1","workerId":"recent-research","workerVersion":"abc123",
          "status":"completed","input":{"query":"Tron"},"output":{"items":[1,2]},
          "error":null,"idempotencyKey":"test-key","traceId":"trace-1","causalDepth":1,
          "agentSessionId":"sess_worker_child",
          "triggerKind":"manual","attemptCount":2,"createdAt":"2026-07-19T12:00:00Z",
          "startedAt":"2026-07-19T12:00:01Z","completedAt":"2026-07-19T12:00:02Z"
        }],"truncated":true,"nextOffset":20}
        """#
        let inboxJSON = #"""
        {"items":[{
          "inboxId":"inbox-1","invocationId":"run-1","workerId":"recent-research",
          "severity":"info","result":{"items":[1,2]},"contextAttached":false,
          "triggerKind":"manual","hasInvocation":true,"requiresAttention":false,
          "createdAt":"2026-07-19T12:00:02Z"
        }],"truncated":false,"nextOffset":null}
        """#

        let runs = try JSONDecoder().decode(WorkerRunsResultDTO.self, from: Data(runJSON.utf8))
        let inbox = try JSONDecoder().decode(WorkerInboxResultDTO.self, from: Data(inboxJSON.utf8))

        #expect(runs.runs.first?.status == "completed")
        #expect(runs.runs.first?.attemptCount == 2)
        #expect(runs.runs.first?.agentSessionId == "sess_worker_child")
        #expect(runs.runs.first?.output != nil)
        #expect(runs.truncated == true)
        #expect(runs.nextOffset == 20)
        #expect(inbox.items.first?.contextAttached == false)
        #expect(inbox.items.first?.requiresAttention == false)
        #expect(inbox.nextOffset == nil)
        let result = try #require(inbox.items.first?.result.value as? [String: Any])
        #expect((result["items"] as? [Any])?.count == 2)
    }
}
