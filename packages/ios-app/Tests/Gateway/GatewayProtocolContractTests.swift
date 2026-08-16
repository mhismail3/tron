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
          "stats":{"userMessages":1,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":1,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"latestCacheHitRate":99.7,"cost":0},
          "queued":{"steering":[],"followUp":["later"]},
          "queueRevision":4,
          "queuedItems":[{"id":"queued-1","behavior":"followUp","text":"later","attachmentCount":2}],
          "transcript":[
            {"id":"entry-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"entry-1:0","type":"text","text":"hello"},{"id":"entry-1:1","type":"text","text":"notes.pdf","attachment":{"name":"notes.pdf","mimeType":"application/pdf","size":2048}}]},
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
        #expect(snapshot.transcript.first?.content?.last?.type == .text)
        #expect(snapshot.transcript.first?.content?.last?.attachment?.name == "notes.pdf")
        #expect(snapshot.transcript.first?.content?.last?.attachment?.size == 2048)
        #expect(snapshot.transcriptStart == 10)
        #expect(snapshot.transcriptTotal == 12)
        #expect(snapshot.stats.latestCacheHitRate == 99.7)
        #expect(snapshot.queueRevision == 4)
        #expect(snapshot.displayedQueuedMessages == [SessionSnapshot.QueuedMessage(
            id: "queued-1",
            behavior: .followUp,
            text: "later",
            attachmentCount: 2
        )])
    }

    @Test("dashboard summary update carries a monotonic revision")
    func summaryUpdateDecodes() throws {
        let data = Data(#"{"sessionId":"session-1","summaryRevision":7,"phase":"running","updatedAt":"2026-01-01T00:00:01Z","messageCount":2,"firstMessage":"hello"}"#.utf8)
        let update = try JSONDecoder.gateway.decode(SessionSummaryUpdate.self, from: data)
        #expect(update.summaryRevision == 7)
        #expect(update.phase == .running)
    }

    @Test("flat session-tree projection decodes")
    func treeDecodes() throws {
        let data = Data(#"[{"id":"entry","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","preview":"hello","role":"user","depth":0,"childCount":1,"isCurrentPath":true}]"#.utf8)
        let nodes = try JSONDecoder.gateway.decode([SessionTreeNode].self, from: data)
        #expect(nodes.first?.role == .user)
        #expect(nodes.first?.isCurrentPath == true)
        #expect(nodes.first?.depth == 0)
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

    @Test("iOS only requests restart from a drain-capable Gateway")
    func safeRestartCapability() {
        #expect(!AppModel.supportsSafeGatewayRestart(capabilities: ["sessions.v1"]))
        #expect(AppModel.supportsSafeGatewayRestart(capabilities: ["sessions.v1", "restart-drain.v1"]))
    }

    @Test("gateway failure is a localized error")
    func failure() {
        let value = GatewayFailure(code: "busy", message: "Session busy", retryable: true, details: nil)
        #expect(value.localizedDescription == "Session busy")
    }
}
