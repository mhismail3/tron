import Foundation
import Testing
@testable import TronMobile

@Suite("Agent Coordination DTO Tests")
struct AgentCoordinationDTOTests {
    @Test("Relationship decoding defaults additive fields without losing unknown states")
    func relationDecodingIsForwardCompatible() throws {
        let relation = try JSONDecoder().decode(AgentRelationDTO.self, from: Data(#"""
        {
          "agentId":"agent-1",
          "relationship":"future_peer_kind",
          "status":"future_paused_state",
          "name":"Analysis agent"
        }
        """#.utf8))

        #expect(relation.agentId == "agent-1")
        #expect(relation.relationship == "future_peer_kind")
        #expect(relation.status == "future_paused_state")
        #expect(relation.depth == 0)
        #expect(relation.allowedActions.isEmpty)
        #expect(relation.transcriptSessionId == nil)
    }

    @Test("Inspect decoding retains server-authored disabled action reasons")
    func inspectDecodingRetainsActionGating() throws {
        let inspect = try JSONDecoder().decode(AgentInspectDTO.self, from: Data(#"""
        {
          "agentId":"agent-1",
          "name":"Analysis agent",
          "relationship":"child",
          "status":"running",
          "grants":[],
          "limits":[],
          "writeScopes":[],
          "lineage":[],
          "contacts":[],
          "allowedActions":[
            {"action":"promote","enabled":false,"disabledReason":"Wait for active work to finish","affectedCount":3}
          ]
        }
        """#.utf8))

        let action = try #require(inspect.allowedActions.first)
        #expect(action.action == "promote")
        #expect(!action.enabled)
        #expect(action.disabledReason == "Wait for active work to finish")
        #expect(action.affectedCount == 3)
    }

    @Test("Usage decoding tolerates partial old-server projections")
    func partialUsageDefaultsToZero() throws {
        let usage = try JSONDecoder().decode(AgentUsageDTO.self, from: Data(#"""
        {"inputTokens":1200,"cost":0.02}
        """#.utf8))

        #expect(usage.inputTokens == 1_200)
        #expect(usage.outputTokens == 0)
        #expect(usage.cacheReadTokens == 0)
        #expect(usage.cost == 0.02)
    }

    @Test("Assignment decoding keeps retry lineage and exact durable result references")
    func assignmentDecodingKeepsResultAndRetryLineage() throws {
        let assignment = try JSONDecoder().decode(AgentAssignmentDTO.self, from: Data(#"""
        {
          "assignmentId":"assignment-2",
          "kind":"instruction",
          "status":"completed",
          "task":"Review the protocol",
          "retryOf":"assignment-1",
          "result":{
            "kind":"agent_assignment",
            "status":"completed",
            "preview":"Review complete",
            "resultId":"result-2",
            "workerInvocationId":null,
            "value":{"summary":"Review complete"}
          }
        }
        """#.utf8))

        #expect(assignment.retryOf == "assignment-1")
        #expect(assignment.result?.resultId == "result-2")
        #expect(assignment.result?.value?.dictionaryValue?["summary"] as? String == "Review complete")
    }

    @Test("Paged result decoding preserves integrity and child navigation")
    func pagedResultDecodingPreservesReferenceEvidence() throws {
        let chunk = try JSONDecoder().decode(AgentResultChunkDTO.self, from: Data(#"""
        {
          "kind":"agent_result",
          "reference":{
            "kind":"agent_assignment",
            "resultId":"result-2",
            "assignmentId":"assignment-2",
            "contentSha256":"abc123",
            "sizeBytes":4096,
            "preview":"Review complete"
          },
          "pointer":"",
          "value":{"summary":"Review complete"},
          "children":[{
            "pointer":"/summary",
            "type":"string",
            "sizeBytes":15,
            "preview":"Review complete"
          }],
          "offset":0,
          "returned":1,
          "total":1,
          "nextOffset":null,
          "truncated":false
        }
        """#.utf8))

        #expect(chunk.reference.resultId == "result-2")
        #expect(chunk.reference.contentSha256 == "abc123")
        #expect(chunk.children.first?.pointer == "/summary")
        #expect(chunk.nextOffset == nil)
        #expect(!chunk.truncated)
    }
}
