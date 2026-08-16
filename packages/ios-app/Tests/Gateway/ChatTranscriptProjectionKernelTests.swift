import Foundation
import Testing
@testable import TronMobile

@Suite("Chat transcript projection kernel")
struct ChatTranscriptProjectionKernelTests {
    @Test("cold candidate owns ordered raw atoms and exact assembled behavior")
    func rawAtomsAndAssembly() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"bootstrap-model","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"modelChange","modelRef":{"provider":"test","id":"old"}},
          {"id":"assistant","parentId":"bootstrap-model","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
            {"id":"thinking","type":"thinking","text":"Checking"},
            {"id":"call-part","type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"README.md"}},
            {"id":"answer","type":"text","text":"Done"}
          ]},
          {"id":"result","parentId":"assistant","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"contents"}],"toolCallId":"call","toolName":"read","isError":false},
          {"id":"bash","parentId":"result","timestamp":"2026-01-01T00:00:03Z","kind":"bash","command":"pwd","output":"/workspace","exitCode":0,"cancelled":false,"truncated":false},
          {"id":"compact","parentId":"bash","timestamp":"2026-01-01T00:00:04Z","kind":"compaction","summary":"summary","tokensBefore":1200}
        ]
        """)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = snapshot.transcript.count
        snapshot.streaming = try JSONDecoder.gateway.decode(TranscriptItem.self, from: Data("""
        {"id":"streaming-source","parentId":"compact","timestamp":"2026-01-01T00:00:05Z","kind":"message","role":"assistant","content":[
          {"id":"stream-thinking","type":"thinking","text":"Finishing"},
          {"id":"stream-answer","type":"text","text":"Streaming"}
        ]}
        """.utf8))

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let assistantParts = ChatTranscriptPresentation.messageParts(in: snapshot.transcript[1])
        let streaming = try #require(snapshot.streaming)
        let streamingParts = ChatTranscriptPresentation.messageParts(in: streaming)

        #expect(candidate.fragments.map(\.source) == snapshot.transcript)
        #expect(candidate.fragments.map(\.atoms) == [
            [.configuration, .notification, .transcriptBarrier],
            [
                .conversationStart,
                .messagePart(assistantParts[0]),
                .toolCall("call"),
                .messagePart(assistantParts[1]),
                .messagePart(assistantParts[2]),
            ],
            [.conversationStart, .toolResult("call"), .transcriptBarrier],
            [.transcriptBarrier],
            [.notification, .transcriptBarrier],
        ])
        #expect(candidate.streamingFragment?.source == streaming)
        #expect(candidate.streamingFragment?.atoms == [
            .conversationStart,
            .messagePart(streamingParts[0]),
            .messagePart(streamingParts[1]),
        ])
        #expect(candidate.timeline.ids == [
            "assistant", "tool-run-call", "assistant-slice-content-answer", "bash",
            "notification-compaction-slot-4", "streaming",
        ])
        guard case .toolRun(let run) = candidate.timeline.items[1] else {
            Issue.record("Expected canonical joined tool run")
            return
        }
        #expect(run.tools.first?.content == "contents")
        #expect(run.tools.first?.request == .object(["path": .string("README.md")]))
        #expect(candidate.timeline.renderedIDBySemanticID["call"] == "tool-run-call")
        #expect(candidate.timeline.preferredSemanticIDByRenderedID["tool-run-call"] == "call")
        #expect(candidate.isValid)
        #expect(ChatTranscriptPresentation.timeline(in: snapshot) == candidate.timeline)
    }

    @Test("global assembler owns bootstrap filtering and orphan result visibility")
    func bootstrapAndOrphan() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"model-bootstrap","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"modelChange","modelRef":{"provider":"test","id":"bootstrap"}},
          {"id":"thinking-bootstrap","parentId":"model-bootstrap","timestamp":"2026-01-01T00:00:01Z","kind":"thinkingChange","level":"low"},
          {"id":"orphan","parentId":"thinking-bootstrap","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"orphan-text","type":"text","text":"orphan output"}],"toolCallId":"orphan-call","toolName":"read","isError":false},
          {"id":"model-later","parentId":"orphan","timestamp":"2026-01-01T00:00:03Z","kind":"modelChange","modelRef":{"provider":"test","id":"later"}}
        ]
        """)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 4

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.ids == ["tool-run-orphan-call", "notification-model-later"])
        #expect(candidate.timeline.renderedIDBySemanticID["orphan-call"] == "tool-run-orphan-call")
        #expect(candidate.timeline.renderedIDBySemanticID["model-later"] == "notification-model-later")
        #expect(candidate.isValid)
    }

    @Test("call references on malformed result content preserve canonical suppression")
    func malformedResultContentCallReference() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"result","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"toolResult","content":[{"id":"text","type":"text","text":"output","toolCallId":"call"}],"toolCallId":"call","toolName":"read","isError":false}]
        """)
        snapshot.transcriptTotal = 1

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        #expect(candidate.fragments[0].atoms == [
            .conversationStart,
            .toolResult("call"),
            .toolCall("call"),
            .transcriptBarrier,
        ])
        #expect(candidate.timeline.items.isEmpty)
        #expect(candidate.isValid)
    }

    @Test("compaction ordinals require exact unique global bounds")
    func compactionOrdinalValidity() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"compact","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"summary","tokensBefore":10}]
        """)
        snapshot.transcriptStart = 9
        snapshot.transcriptTotal = 10
        #expect(ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline.ids == [
            "notification-compaction-slot-9",
        ])

        snapshot.transcriptTotal = 99
        #expect(ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline.ids == [
            "notification-compaction-compact",
        ])

        snapshot.transcript.append(snapshot.transcript[0])
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 2
        let duplicate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(duplicate.timeline.ids == [
            "notification-compaction-compact", "notification-compaction-compact",
        ])
        #expect(!duplicate.isValid)
    }

    @Test("cold work reports exact aggregate-only counts")
    func aggregateWorkReport() throws {
        let snapshot = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"private prompt"}]}]
        """)
        let recorder = ProjectionWorkRecorder()
        let candidate = ChatTranscriptProjectionKernel.cold(
            snapshot: snapshot,
            workRecorder: recorder.record
        )

        #expect(candidate.workReport == ChatTranscriptProjectionWorkReport(
            mode: .cold,
            sourceEntriesExamined: 1,
            fragmentsReused: 0,
            fragmentsRebuilt: 1,
            toolsInspected: 0,
            toolsPatched: 0,
            atomsAssembled: 2,
            renderedItemCount: 1
        ))
        #expect(recorder.reports == [candidate.workReport])
        #expect(Set(Mirror(reflecting: candidate.workReport).children.compactMap(\.label)) == [
            "mode", "sourceEntriesExamined", "fragmentsReused", "fragmentsRebuilt",
            "toolsInspected", "toolsPatched", "atomsAssembled", "renderedItemCount",
        ])
    }

    @Test("100 and 256 unanchored tools stay one deterministic valid run", arguments: [100, 256])
    func largeToolBursts(count: Int) throws {
        let builder = SessionScenarioBuilder(seed: 1_301 + count)
        var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
        snapshot.transcript = []
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 0
        snapshot.phase = .running
        snapshot.toolExecutions = Array(builder.liveToolBurst(count: count).reversed())

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected one runtime tool run")
            return
        }
        #expect(candidate.timeline.items.count == 1)
        #expect(run.tools.count == count)
        #expect(run.tools.map(\.id) == builder.liveToolBurst(count: count).map(\.toolCallId))
        #expect(candidate.workReport.toolsInspected == count)
        #expect(candidate.isValid)
    }

    @Test("duplicate tools keep first run order and replace with the newest presentation")
    func duplicateToolOrderAndReplacement() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [
            runtimeTool(id: "duplicate", order: 0, output: "older"),
            runtimeTool(id: "between", order: 1, output: "middle"),
            runtimeTool(id: "duplicate", order: 2, output: "newest"),
        ]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected one deduplicated runtime tool run")
            return
        }
        #expect(candidate.timeline.items.count == 1)
        #expect(run.tools.map(\.id) == ["duplicate", "between"])
        #expect(run.tools.map(\.content) == ["newest", "middle"])
        #expect(candidate.timeline.renderedIDBySemanticID["duplicate"] == "tool-run-duplicate")
        #expect(candidate.timeline.renderedIDBySemanticID["between"] == "tool-run-duplicate")
        #expect(candidate.isValid)
    }

    @Test("streaming calls and unanchored runtime tools share canonical global ordering")
    func streamingAndUnanchoredTools() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.streaming = try JSONDecoder.gateway.decode(TranscriptItem.self, from: Data("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Working"},
          {"id":"call-part","type":"toolCall","toolCallId":"anchored","name":"read","arguments":{}}
        ]}
        """.utf8))
        snapshot.toolExecutions = [
            runtimeTool(id: "unanchored", order: 1),
            runtimeTool(id: "anchored", order: 0),
        ]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.ids == ["streaming", "tool-run-anchored"])
        guard case .toolRun(let run) = candidate.timeline.items.last else {
            Issue.record("Expected consolidated streaming/runtime tool run")
            return
        }
        #expect(run.tools.map(\.id) == ["anchored", "unanchored"])
        #expect(candidate.timeline.renderedIDBySemanticID["anchored"] == "tool-run-anchored")
        #expect(candidate.timeline.renderedIDBySemanticID["unanchored"] == "tool-run-anchored")
        #expect(candidate.isValid)
    }

    @Test("cold candidate retains all explicitly loaded history beyond page size")
    func loadedHistoryBeyondPageSize() throws {
        let builder = SessionScenarioBuilder(seed: 1_401)
        var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
        let count = ChatTranscriptPageRequest.maximumItemCount + 257
        snapshot.transcript = builder.pagedMixedSession(totalEntries: count).page(before: count, count: count)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = count

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let firstID = "scenario-00000579-00000000"
        let orphanCallID = "scenario-00000579-00000002-call"
        let orphanRunID = "tool-run-\(orphanCallID)"
        let compactionID = "scenario-00000579-00000004"
        let compactionRenderedID = "notification-compaction-slot-4"
        let lastID = "scenario-00000579-00000768"

        #expect(candidate.fragments.count == 769)
        #expect(candidate.workReport.sourceEntriesExamined == 769)
        #expect(candidate.workReport.fragmentsRebuilt == 769)
        #expect(candidate.workReport.renderedItemCount == 769)
        #expect(candidate.timeline.items.count == 769)
        #expect(candidate.timeline.items.first?.id == firstID)
        #expect(candidate.timeline.items.last?.id == lastID)
        #expect(candidate.timeline.preferredSemanticIDByRenderedID[firstID] == firstID)
        #expect(candidate.timeline.renderedIDBySemanticID[firstID] == firstID)
        #expect(candidate.timeline.preferredSemanticIDByRenderedID[orphanRunID] == orphanCallID)
        #expect(candidate.timeline.renderedIDBySemanticID[orphanCallID] == orphanRunID)
        #expect(candidate.timeline.preferredSemanticIDByRenderedID[compactionRenderedID] == compactionID)
        #expect(candidate.timeline.renderedIDBySemanticID[compactionID] == compactionRenderedID)
        #expect(candidate.timeline.preferredSemanticIDByRenderedID[lastID] == lastID)
        #expect(candidate.timeline.renderedIDBySemanticID[lastID] == lastID)
        #expect(candidate.timeline.isInternallyConsistent)
        #expect(candidate.isValid)
    }

    private func runtimeTool(id: String, order: Int, output: String? = nil) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: id,
            toolName: "read",
            order: order,
            status: .running,
            arguments: .object([:]),
            partialResult: nil,
            result: nil,
            output: output,
            isError: false,
            startedAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            lastProgressAt: "2026-01-01T00:00:00Z",
            progressSequence: 1
        )
    }

    private func fixture(transcript: String) throws -> SessionSnapshot {
        try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data("""
        {
          "sessionId":"session","runtimeGeneration":"generation","revision":1,"eventSequence":1,"phase":"idle","cwd":"/workspace",
          "model":{"provider":"test","id":"model"},"thinkingLevel":"high","availableThinkingLevels":["off","high"],
          "stats":{"userMessages":0,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0},
          "queued":{"steering":[],"followUp":[]},"transcript":\(transcript),"transcriptStart":0,"transcriptTotal":0,
          "toolExecutions":[],"extensionUI":{"statuses":{},"working":{"visible":false},"widgets":[],"editorRevision":0,"editorText":"","pendingInteractions":[]},"diagnostics":[]
        }
        """.utf8))
    }
}

private final class ProjectionWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ChatTranscriptProjectionWorkReport] = []

    var reports: [ChatTranscriptProjectionWorkReport] { lock.withLock { storage } }

    func record(_ report: ChatTranscriptProjectionWorkReport) {
        lock.withLock { storage.append(report) }
    }
}
