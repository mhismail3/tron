import Foundation
import Testing
@testable import TronMobile

@Suite("Gateway protocol fixtures")
struct GatewayProtocolContractTests {
    @Test("authoritative session snapshot decodes")
    func snapshotDecodes() throws {
        let data = Data(#"""
        {
          "sessionId":"session-1","runtimeGeneration":"generation-1","revision":8,"eventSequence":21,"phase":"running","cwd":"/workspace",
          "model":{"provider":"anthropic","id":"model"},"thinkingLevel":"high",
          "availableThinkingLevels":["off","high"],
          "contextUsage":{"tokens":120,"contextWindow":1000,"percent":12},
          "stats":{"userMessages":1,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":1,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0},
          "queued":{"steering":[],"followUp":["later"]},
          "transcript":[
            {"id":"entry-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"entry-1:0","type":"text","text":"hello"}]},
            {"id":"entry-2","parentId":"entry-1","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai","id":"next"}}
          ],"transcriptStart":10,"transcriptTotal":12,
          "leafEntryId":"entry-2","toolExecutions":[],
          "extensionUI":{"statuses":{},"working":{"visible":true},"widgets":[],"editorRevision":0,"editorText":"","pendingInteractions":[]},
          "diagnostics":[]
        }
        """#.utf8)
        let snapshot = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: data)
        #expect(snapshot.sessionId == "session-1")
        #expect(snapshot.model == ModelRef(provider: "anthropic", id: "model"))
        #expect(snapshot.transcript.first?.text == "hello")
        #expect(snapshot.transcript.last?.modelRef == ModelRef(provider: "openai", id: "next"))
        #expect(snapshot.transcript.first?.content?.first?.id == "entry-1:0")
        #expect(snapshot.transcriptStart == 10)
        #expect(snapshot.transcriptTotal == 12)
    }

    @Test("stored gateway profiles migrate when device identity was absent")
    func profileMigration() throws {
        let data = Data(#"{"id":"machine","label":"Mac","host":"100.64.0.1","port":9847,"machineId":"machine"}"#.utf8)
        let profile = try JSONDecoder().decode(GatewayProfile.self, from: data)
        #expect(profile.deviceId == nil)
    }

    @Test("authorized device projection decodes")
    func pairedDeviceDecodes() throws {
        let data = Data(#"{"id":"device","name":"Phone","createdAt":"2026-01-01T00:00:00Z"}"#.utf8)
        #expect(try JSONDecoder().decode(PairedDevice.self, from: data).name == "Phone")
    }

    @Test("provider-qualified model identity does not collide")
    func modelIdentity() {
        #expect(ModelRef(provider: "one", id: "shared") != ModelRef(provider: "two", id: "shared"))
    }

    @Test("model pages decode with an optional continuation cursor")
    func modelPageDecodes() throws {
        struct Page: Decodable { let models: [ModelSummary]; let nextCursor: String? }
        let data = Data(#"{"models":[{"provider":"extension","id":"model","name":"Model","reasoning":false,"input":["text"],"contextWindow":4096,"maxTokens":1024,"available":true}],"nextCursor":"500"}"#.utf8)
        let page = try JSONDecoder.gateway.decode(Page.self, from: data)
        #expect(page.models.first?.ref == ModelRef(provider: "extension", id: "model"))
        #expect(page.nextCursor == "500")
    }

    @Test("gateway failure is a localized error")
    func failure() {
        let value = GatewayFailure(code: "busy", message: "Session busy", retryable: true, details: nil)
        #expect(value.localizedDescription == "Session busy")
    }
}
