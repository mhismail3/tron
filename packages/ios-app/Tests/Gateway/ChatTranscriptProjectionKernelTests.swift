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
        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
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
        let detail = try #require(run.tools.first.flatMap(candidate.toolPayloads.resolving))
        #expect(detail.content == "contents")
        #expect(detail.request == .object(["path": .string("README.md")]))
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

    @Test("duplicate tools use the newest canonical state for deterministic order and payload")
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
        #expect(run.tools.map(\.id) == ["between", "duplicate"])
        #expect(run.tools.compactMap(candidate.toolPayloads.resolving).map(\.content) == ["middle", "newest"])
        #expect(candidate.timeline.renderedIDBySemanticID["duplicate"] == "tool-run-between")
        #expect(candidate.timeline.renderedIDBySemanticID["between"] == "tool-run-between")
        #expect(candidate.isValid)
    }

    @Test("duplicate call identities across separate runs fail projection admission")
    func duplicateCallIDsAcrossRunsFailClosed() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-one","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-one","type":"toolCall","toolCallId":"duplicate","name":"read","arguments":{"path":"one"}}]},
          {"id":"user","parentId":"assistant-one","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"continue"}]},
          {"id":"assistant-two","parentId":"user","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-two","type":"toolCall","toolCallId":"duplicate","name":"read","arguments":{"path":"two"}}]}
        ]
        """)
        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }.flatMap(\.tools).map(\.id) == ["duplicate", "duplicate"])
        #expect(!candidate.isValid)
    }

    @Test("streaming calls and unanchored runtime tools share canonical global ordering")
    func streamingAndUnanchoredTools() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
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

    @Test("exact ordinal reuse rebuilds one sparse middle entry beyond 512 with cold parity")
    func sparseMiddleReuse() throws {
        let builder = SessionScenarioBuilder(seed: 1_402)
        var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
        let count = ChatTranscriptPageRequest.maximumItemCount + 257
        snapshot.transcript = builder.historyPage(count: count, longRowBytes: 24)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = count
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        snapshot.transcript[count / 2] = try transcriptItem(
            id: "replacement-middle",
            text: "changed"
        )
        snapshot.revision += 1
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: false
        )
        let cold = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        #expect(incremental.timeline == cold.timeline)
        #expect(incremental.workReport.mode == .fragmentReuse)
        #expect(incremental.workReport.fragmentsReused == count - 1)
        #expect(incremental.workReport.fragmentsRebuilt == 1)
        #expect(incremental.workReport.sourceEntriesExamined == count)
        #expect(incremental.timeline.ids == cold.timeline.ids)
        #expect(incremental.timeline.preferredSemanticIDByRenderedID == cold.timeline.preferredSemanticIDByRenderedID)
        #expect(incremental.timeline.renderedIDBySemanticID == cold.timeline.renderedIDBySemanticID)
    }

    @Test("exact prepend append and rollover align by global ordinal intersection")
    func exactWindowEvolution() throws {
        let original = [
            try transcriptItem(id: "a", text: "a"),
            try transcriptItem(id: "b", text: "b"),
            try transcriptItem(id: "c", text: "c"),
        ]
        var snapshot = try fixture(transcript: "[]")
        snapshot.transcript = original
        snapshot.transcriptStart = 10
        snapshot.transcriptTotal = 13
        let base = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        snapshot.transcript.insert(try transcriptItem(id: "older", text: "older"), at: 0)
        snapshot.transcriptStart = 9
        let prepended = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: base,
            canonicalSourceUnchanged: false
        )
        #expect(prepended.workReport.fragmentsReused == 3)
        #expect(prepended.workReport.fragmentsRebuilt == 1)
        #expect(prepended.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)

        var appendSnapshot = try fixture(transcript: "[]")
        appendSnapshot.transcript = original
        appendSnapshot.transcriptStart = 0
        appendSnapshot.transcriptTotal = 3
        let appendBase = ChatTranscriptProjectionKernel.cold(snapshot: appendSnapshot)
        appendSnapshot.transcript.append(try transcriptItem(id: "d", text: "d"))
        appendSnapshot.transcriptTotal = 4
        let appended = ChatTranscriptProjectionKernel.incremental(
            snapshot: appendSnapshot,
            previous: appendBase,
            canonicalSourceUnchanged: false
        )
        #expect(appended.workReport.fragmentsReused == 3)
        #expect(appended.workReport.fragmentsRebuilt == 1)

        var rollover = appendSnapshot
        rollover.transcript.removeFirst()
        rollover.transcript.append(try transcriptItem(id: "e", text: "e"))
        rollover.transcriptStart = 1
        rollover.transcriptTotal = 5
        let rolled = ChatTranscriptProjectionKernel.incremental(
            snapshot: rollover,
            previous: appended,
            canonicalSourceUnchanged: false
        )
        #expect(rolled.workReport.fragmentsReused == 3)
        #expect(rolled.workReport.fragmentsRebuilt == 1)
        #expect(rolled.timeline == ChatTranscriptProjectionKernel.cold(snapshot: rollover).timeline)
    }

    @Test("same ID changed payload rebuilds while duplicate inexact spines stay cold")
    func payloadAndDuplicateProof() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.transcript = [
            try transcriptItem(id: "same", text: "old"),
            try transcriptItem(id: "stable", text: "stable"),
        ]
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 2
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.transcript[0] = try transcriptItem(id: "same", text: "new")
        let changed = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: false
        )
        #expect(changed.workReport.fragmentsReused == 1)
        #expect(changed.workReport.fragmentsRebuilt == 1)
        #expect(changed.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)

        snapshot.transcript = [snapshot.transcript[0], snapshot.transcript[0]]
        snapshot.transcriptStart = nil
        snapshot.transcriptTotal = nil
        let duplicateBase = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.transcript[1] = try transcriptItem(id: "same", text: "newer")
        let duplicate = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: duplicateBase,
            canonicalSourceUnchanged: false
        )
        #expect(duplicate.workReport.mode == .cold)
        #expect(duplicate.workReport.fragmentsReused == 0)
        #expect(duplicate.workReport.fragmentsRebuilt == 2)
    }

    @Test("inexact unique ordered spine permits only exact source equality")
    func inexactOrderedSpine() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.transcript = [
            try transcriptItem(id: "one", text: "one"),
            try transcriptItem(id: "two", text: "two"),
            try transcriptItem(id: "three", text: "three"),
        ]
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 99
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.transcript[1] = try transcriptItem(id: "two", text: "changed")
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: false
        )
        #expect(incremental.workReport.fragmentsReused == 2)
        #expect(incremental.workReport.fragmentsRebuilt == 1)
        #expect(incremental.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
    }

    @Test("completed extension tool results retain provenance in the canonical row")
    func completedExtensionToolResultRetainsProvenance() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"result","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"toolResult","content":[{"id":"text","type":"text","text":"done"}],"toolCallId":"extension-call","toolName":"subagent","isError":false,"extensionOrigin":{"source":"pi-subagents"}}]
        """)
        snapshot.transcriptTotal = 1
        #expect(snapshot.transcript.first?.extensionOrigin == ExtensionToolOrigin(source: "pi-subagents"))
        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first,
              let tool = run.tools.first else {
            Issue.record("Expected canonical extension tool result row")
            return
        }
        #expect(tool.extensionOrigin == ExtensionToolOrigin(source: "pi-subagents"))
        #expect(tool.title == "subagent")
    }

    @Test("canonical result changes always globally assemble")
    func canonicalResultChangeAssembles() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"call-entry","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part","type":"toolCall","toolCallId":"call","name":"read","arguments":{}}]},
          {"id":"result","parentId":"call-entry","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"old"}],"toolCallId":"call","toolName":"read","isError":false}
        ]
        """)
        snapshot.transcriptTotal = 2
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.transcript[1] = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"result","parentId":"call-entry","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"new"}],"toolCallId":"call","toolName":"read","isError":false}
        """.utf8))
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: false
        )
        #expect(incremental.workReport.mode == .fragmentReuse)
        #expect(incremental.workReport.toolsPatched == 0)
        #expect(incremental.workReport.atomsAssembled > 0)
        #expect(incremental.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
        guard case .toolRun(let run) = incremental.timeline.items.first else {
            Issue.record("Expected joined tool result")
            return
        }
        #expect(run.tools.first.flatMap(incremental.toolPayloads.resolving)?.content == "new")
    }

    @Test("collision admission rebases later sparse tool patch sites")
    func collisionAdmissionRebasesToolPatch() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"bash","command":"one","output":"","cancelled":false,"truncated":false},
          {"id":"duplicate","parentId":"duplicate","timestamp":"2026-01-01T00:00:01Z","kind":"bash","command":"two","output":"","cancelled":false,"truncated":false}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [runtimeTool(id: "live", order: 0, output: "old")]
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(previous.timeline.ids == ["duplicate", "tool-run-live"])

        snapshot.toolExecutions = [updatedTool(snapshot.toolExecutions[0], output: "new")]
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: true
        )
        #expect(incremental.workReport.mode == .toolPayloadPatch)
        #expect(incremental.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
    }

    @Test("one runtime tool payload update patches one flat row in ten thousand history entries")
    func tenThousandToolPatch() throws {
        let builder = SessionScenarioBuilder(seed: 1_403)
        var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
        snapshot.transcript = builder.historyPage(count: 10_000, longRowBytes: 8)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 10_000
        snapshot.phase = .running
        snapshot.toolExecutions = [runtimeTool(id: "live", order: 0, output: "old")]
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.toolExecutions = [updatedTool(snapshot.toolExecutions[0], output: "new")]

        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: true
        )
        let cold = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(incremental.workReport == ChatTranscriptProjectionWorkReport(
            mode: .toolPayloadPatch,
            sourceEntriesExamined: 0,
            fragmentsReused: 0,
            fragmentsRebuilt: 0,
            toolsInspected: 1,
            toolsPatched: 1,
            atomsAssembled: 0,
            renderedItemCount: cold.timeline.items.count
        ))
        #expect(incremental.timeline == cold.timeline)
        #expect(incremental.toolPayloads == cold.toolPayloads)
        #expect(incremental.timeline.items.sparseOverrideCount == 1)
        #expect(incremental.timeline.ids == cold.timeline.ids)
        #expect(incremental.timeline.preferredSemanticIDByRenderedID == previous.timeline.preferredSemanticIDByRenderedID)
        #expect(incremental.timeline.renderedIDBySemanticID == previous.timeline.renderedIDBySemanticID)
    }

    @Test("one change in large runtime runs patches exactly one descriptor", arguments: [100, 256])
    func sparseLargeRunPatch(count: Int) throws {
        let builder = SessionScenarioBuilder(seed: 1_404 + count)
        var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
        snapshot.transcript = []
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 0
        snapshot.phase = .running
        snapshot.toolExecutions = builder.liveToolBurst(count: count)
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.toolExecutions[count / 2] = updatedTool(
            snapshot.toolExecutions[count / 2],
            output: "changed"
        )
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: true
        )
        #expect(incremental.workReport.mode == .toolPayloadPatch)
        #expect(incremental.workReport.toolsInspected == count)
        #expect(incremental.workReport.toolsPatched == 1)
        #expect(incremental.timeline.items.sparseOverrideCount == 1)
        let cold = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(incremental.timeline == cold.timeline)
        #expect(incremental.toolPayloads == cold.toolPayloads)
    }

    @Test("anchored completion patches only while placement stays stable")
    func anchoredCompletionPatch() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part","type":"toolCall","toolCallId":"call","name":"read","arguments":{}}]}]
        """)
        snapshot.transcriptTotal = 1
        snapshot.phase = .running
        snapshot.toolExecutions = [runtimeTool(id: "call", order: 0)]
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.toolExecutions = [updatedTool(
            snapshot.toolExecutions[0],
            status: .completed,
            output: "done"
        )]
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: true
        )
        #expect(incremental.workReport.mode == .toolPayloadPatch)
        #expect(incremental.timeline.ids == previous.timeline.ids)
        #expect(incremental.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
    }

    @Test("tool patch falls back for phase membership order start and duplicate changes")
    func structuralToolFallbacks() throws {
        var baseSnapshot = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"prompt"}]}]
        """)
        baseSnapshot.transcriptTotal = 1
        baseSnapshot.phase = .running
        baseSnapshot.toolExecutions = [runtimeTool(id: "one", order: 0)]
        let base = ChatTranscriptProjectionKernel.cold(snapshot: baseSnapshot)

        var phase = baseSnapshot
        phase.phase = .idle
        phase.toolExecutions = [updatedTool(phase.toolExecutions[0], output: "phase")]
        #expect(ChatTranscriptProjectionKernel.incremental(
            snapshot: phase, previous: base, canonicalSourceUnchanged: true
        ).workReport.mode != .toolPayloadPatch)

        var membership = baseSnapshot
        membership.toolExecutions.append(runtimeTool(id: "two", order: 1))
        #expect(ChatTranscriptProjectionKernel.incremental(
            snapshot: membership, previous: base, canonicalSourceUnchanged: true
        ).workReport.mode != .toolPayloadPatch)

        var order = baseSnapshot
        order.toolExecutions = [updatedTool(order.toolExecutions[0], order: 4, output: "order")]
        #expect(ChatTranscriptProjectionKernel.incremental(
            snapshot: order, previous: base, canonicalSourceUnchanged: true
        ).workReport.mode != .toolPayloadPatch)

        var start = baseSnapshot
        start.toolExecutions = [updatedTool(
            start.toolExecutions[0],
            output: "start",
            startedAt: "2026-01-01T00:00:09Z"
        )]
        #expect(ChatTranscriptProjectionKernel.incremental(
            snapshot: start, previous: base, canonicalSourceUnchanged: true
        ).workReport.mode != .toolPayloadPatch)

        var duplicate = baseSnapshot
        duplicate.toolExecutions.append(updatedTool(duplicate.toolExecutions[0], output: "duplicate"))
        #expect(ChatTranscriptProjectionKernel.incremental(
            snapshot: duplicate, previous: base, canonicalSourceUnchanged: true
        ).workReport.mode != .toolPayloadPatch)

        var placement = baseSnapshot
        placement.streaming = try transcriptItem(id: "stream", text: "answer", role: "assistant")
        placement.toolExecutions = [updatedTool(
            placement.toolExecutions[0],
            status: .completed,
            output: "complete"
        )]
        let completed = ChatTranscriptProjectionKernel.cold(snapshot: placement)
        placement.toolExecutions = [updatedTool(
            placement.toolExecutions[0],
            status: .running,
            output: "running"
        )]
        let completedIDs = completed.timeline.ids
        #expect(completedIDs == ["user", "stream"])
        let flipped = ChatTranscriptProjectionKernel.incremental(
            snapshot: placement,
            previous: completed,
            canonicalSourceUnchanged: true
        )
        #expect(flipped.workReport.mode != .toolPayloadPatch)
        #expect(flipped.timeline.ids == ["user", "stream", "tool-run-one"])
        #expect(flipped.timeline == ChatTranscriptProjectionKernel.cold(snapshot: placement).timeline)
    }

    @Test("unanchored tools stay visible only while they are running")
    func stableUnanchoredStreamingPlacement() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [runtimeTool(id: "one", order: 0)]
        let running = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(running.timeline.ids == ["tool-run-one"])

        snapshot.toolExecutions.append(runtimeTool(id: "two", order: 1))
        let grouped = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: running,
            canonicalSourceUnchanged: true
        )
        #expect(grouped.timeline.ids == ["tool-run-one"])
        guard case .toolRun(let groupedRun) = grouped.timeline.items.last else {
            Issue.record("Expected grouped unanchored tools after streaming")
            return
        }
        #expect(groupedRun.tools.map(\.id) == ["one", "two"])

        snapshot.toolExecutions = snapshot.toolExecutions.map {
            updatedTool($0, status: .completed, output: "done-\($0.toolCallId)")
        }
        let completed = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: grouped,
            canonicalSourceUnchanged: true
        )
        #expect(completed.workReport.mode != .toolPayloadPatch)
        #expect(completed.timeline.items.isEmpty)
        #expect(completed.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
    }

    @Test("running unanchored tools remain visible at the current-work tail")
    func runningUnanchoredToolRemainsVisible() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [runtimeTool(id: "running", order: 0)]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.ids == ["tool-run-running"])
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected current running tool overlay")
            return
        }
        #expect(run.tools.map(\.id) == ["running"])
        #expect(run.isRunning)
    }

    @Test("terminal unanchored tools do not synthesize a bottom aggregate")
    func terminalUnanchoredToolsDoNotRenderTailAggregate() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        let completed = updatedTool(runtimeTool(id: "completed", order: 0), status: .completed, output: "done")
        let failed = updatedTool(runtimeTool(id: "failed", order: 1), status: .failed, output: "error")
        snapshot.toolExecutions = [completed, failed]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.items.isEmpty)
        #expect(candidate.timeline.renderedIDBySemanticID["completed"] == nil)
        #expect(candidate.timeline.renderedIDBySemanticID["failed"] == nil)
    }

    @Test("canonical positioned terminal tools preserve thinking and tool order")
    func canonicalPositionedTerminalToolsRemainInTranscriptOrder() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-before","type":"thinking","text":"Planning"},
            {"id":"call","type":"toolCall","toolCallId":"call","name":"read","arguments":{}},
            {"id":"thinking-after","type":"thinking","text":"Editing"}
          ]},
          {"id":"result","parentId":"assistant","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"done"}],"toolCallId":"call","toolName":"read","isError":false}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [updatedTool(runtimeTool(id: "call", order: 0), status: .completed, output: "done")]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.items.count == 3)
        guard case .message = candidate.timeline.items[0],
              case .toolRun(let run) = candidate.timeline.items[1],
              case .message = candidate.timeline.items[2] else {
            Issue.record("Expected canonical tool position")
            return
        }
        #expect(run.tools.map(\.id) == ["call"])
        #expect(run.title == "Read file")
        #expect(!run.isRunning)
    }

    @Test("mixed stale terminal and running unanchored tools show only current work")
    func mixedTerminalAndRunningUnanchoredTools() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [
            updatedTool(runtimeTool(id: "stale", order: 0), status: .completed, output: "done"),
            runtimeTool(id: "current", order: 1),
        ]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.ids == ["tool-run-current"])
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected only the current running overlay")
            return
        }
        #expect(run.tools.map(\.id) == ["current"])
        #expect(run.isRunning)
    }

    @Test("repeated tool patches keep a bounded flat overlay and isolated suffixes preserve parity")
    func flatOverlayAndIsolatedSuffix() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"prompt"}]}]
        """)
        snapshot.transcriptTotal = 1
        snapshot.phase = .running
        snapshot.toolExecutions = [runtimeTool(id: "live", order: 0)]
        var candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        for update in 1...8 {
            snapshot.toolExecutions = [updatedTool(
                snapshot.toolExecutions[0],
                output: "update-\(update)"
            )]
            candidate = ChatTranscriptProjectionKernel.incremental(
                snapshot: snapshot,
                previous: candidate,
                canonicalSourceUnchanged: true
            )
            #expect(candidate.workReport.mode == .toolPayloadPatch)
            #expect(candidate.timeline.items.sparseOverrideCount == 1)
            #expect(candidate.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
        }

        snapshot.toolExecutions = []
        snapshot.streaming = nil
        let canonicalBase = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.streaming = try transcriptItem(id: "stream", text: "first", role: "assistant")
        let streamingBase = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: canonicalBase,
            canonicalSourceUnchanged: true
        )
        snapshot.streaming = try transcriptItem(id: "stream", text: "second", role: "assistant")
        let suffixRecorder = ProjectionWorkRecorder()
        let suffix = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: streamingBase,
            canonicalSourceUnchanged: true,
            workRecorder: suffixRecorder.record
        )
        #expect(suffix.workReport.mode == .isolatedStreamingSuffix)
        #expect(suffix.workReport.sourceEntriesExamined == 1)
        #expect(suffix.timeline.items.canonicalCount == streamingBase.timeline.items.canonicalCount)
        #expect(suffix.timeline.items.live.count == 1)
        let cold = ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline
        #expect(suffix.timeline == cold)
        #expect(suffix.timeline.hashValue == cold.hashValue)
        #expect(suffixRecorder.reports == [suffix.workReport])
    }

    @Test("duplicate unanchored runtime states resolve newest independent of delivery order")
    func duplicateUnanchoredNewestIsOrderIndependent() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        let older = runtimeTool(id: "duplicate", order: 0, output: "older")
        let newer = updatedTool(older, output: "newer")

        snapshot.toolExecutions = [older, newer]
        let forward = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        snapshot.toolExecutions = [newer, older]
        let reversed = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        #expect(forward.timeline == reversed.timeline)
        #expect(forward.timeline.ids == ["tool-run-duplicate"])
        guard case .toolRun(let run) = reversed.timeline.items.first else {
            Issue.record("Expected one deduplicated runtime run")
            return
        }
        #expect(run.tools.map(\.id) == ["duplicate"])
        #expect(run.tools.first.flatMap(reversed.toolPayloads.resolving)?.content == "newer")
        #expect(run.tools.first?.progressSequence == newer.progressSequence)

        let timestampOlder = ToolExecutionState(
            toolCallId: "timestamp-duplicate", toolName: "read", order: 0,
            status: .running, arguments: .object([:]), partialResult: nil, result: nil,
            output: "timestamp-older", isError: false,
            startedAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"
        )
        let timestampNewer = ToolExecutionState(
            toolCallId: "timestamp-duplicate", toolName: "read", order: 0,
            status: .running, arguments: .object([:]), partialResult: nil, result: nil,
            output: "timestamp-newer", isError: false,
            startedAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z"
        )
        snapshot.toolExecutions = [timestampNewer, timestampOlder]
        let timestampReversed = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let timestampRun) = timestampReversed.timeline.items.first else {
            Issue.record("Expected timestamp-deduplicated runtime run")
            return
        }
        #expect(timestampRun.tools.first.flatMap(timestampReversed.toolPayloads.resolving)?.content == "timestamp-newer")
    }

    @Test("streaming calls suppress canonical orphan results and join them at stream order")
    func streamingCallJoinsCanonicalResult() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"prompt","type":"text","text":"continue"}]},
          {"id":"result","parentId":"user","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"canonical output"}],"toolCallId":"stream-call","toolName":"read","isError":false,"details":{"ok":true}}
        ]
        """)
        snapshot.transcriptTotal = 2
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(previous.timeline.ids == ["user", "tool-run-stream-call"])

        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"stream-source","parentId":"result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[
          {"id":"stream-text","type":"text","text":"before tool"},
          {"id":"stream-tool","type":"toolCall","toolCallId":"stream-call","name":"read","arguments":{"path":"README.md"}}
        ]}
        """.utf8))

        let cold = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: true
        )

        #expect(cold.timeline.ids == ["user", "streaming", "tool-run-stream-call"])
        #expect(incremental.timeline == cold.timeline)
        #expect(incremental.toolPayloads == cold.toolPayloads)
        #expect(incremental.workReport.mode == .fragmentReuse)
        #expect(incremental.workReport.fragmentsReused == 2)
        #expect(ChatTranscriptProjectionKernel.visibleItems(in: snapshot).map(\.id) == ["user"])
        guard case .toolRun(let run) = cold.timeline.items.last else {
            Issue.record("Expected joined stream-position tool run")
            return
        }
        let detail = try #require(run.tools.first.flatMap(cold.toolPayloads.resolving))
        #expect(detail.content == "canonical output")
        #expect(detail.response == .object(["ok": .bool(true)]))
        #expect(detail.request == .object(["path": .string("README.md")]))
        #expect(cold.timeline.renderedIDBySemanticID["stream-call"] == "tool-run-stream-call")
        #expect(cold.timeline.preferredSemanticIDByRenderedID["tool-run-stream-call"] == "stream-call")
    }

    @Test("malformed streaming call references keep cold-worker and incremental result placement exact")
    func malformedStreamingCallReferenceParity() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"prompt","type":"text","text":"continue"}]},
          {"id":"result","parentId":"user","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"canonical output"}],"toolCallId":"extension-call","toolName":"extension","isError":false}
        ]
        """)
        snapshot.transcriptTotal = 2
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(previous.timeline.ids == ["user", "tool-run-extension-call"])

        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"stream-source","parentId":"result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[
          {"id":"extension-reference","type":"text","text":"extension output follows","toolCallId":"extension-call"}
        ]}
        """.utf8))

        let streaming = try #require(snapshot.streaming)
        #expect(ChatTranscriptProjectionKernel.isolatedStreamingTimeline(streaming) == nil)
        let cold = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let coldWorker = ChatTranscriptProjectionKernel.coldForWorker(
            snapshot: snapshot,
            performanceSignposts: RecordingPerformanceSignposts(),
            workRecorder: nil
        )
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: true
        )

        #expect(cold.timeline.ids == ["user", "streaming"])
        #expect(coldWorker.timeline == cold.timeline)
        #expect(coldWorker.timeline.items.live.isEmpty)
        #expect(incremental.timeline == cold.timeline)
        #expect(incremental.timeline.items.live.isEmpty)
        #expect(incremental.workReport.mode == .fragmentReuse)
        #expect(ChatTranscriptProjectionKernel.visibleItems(in: snapshot).map(\.id) == ["user"])
        #expect(cold.timeline.renderedIDBySemanticID["extension-call"] == nil)
    }

    @Test("malformed maximum transcript bounds fall back without overflow")
    func maximumBoundsAreConservative() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"compact","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"summary","tokensBefore":10}]
        """)
        snapshot.transcriptStart = Int.max
        snapshot.transcriptTotal = Int.max
        snapshot.phase = .compacting
        snapshot.extensionPresentation.semanticState.working = .init(message: nil, visible: true)

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.ids == ["notification-compaction-compact"])
        #expect(candidate.runtimeItems.map(\.id) == ["runtime-working"])
        #expect(candidate.isValid)
    }

    @Test("distinct sparse row patches stay flat and global assembly clears overrides")
    func distinctOverlaysAndAssemblyReset() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant-one","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-one-part","type":"toolCall","toolCallId":"call-one","name":"read","arguments":{}}]},
          {"id":"separator","parentId":"assistant-one","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"separator-text","type":"text","text":"between"}]},
          {"id":"assistant-two","parentId":"separator","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-two-part","type":"toolCall","toolCallId":"call-two","name":"read","arguments":{}}]}
        ]
        """)
        snapshot.transcriptTotal = 3
        snapshot.phase = .running
        snapshot.toolExecutions = [
            runtimeTool(id: "call-one", order: 0),
            runtimeTool(id: "call-two", order: 1),
        ]
        let base = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        snapshot.toolExecutions[0] = updatedTool(snapshot.toolExecutions[0], output: "one")
        let first = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: base,
            canonicalSourceUnchanged: true
        )
        #expect(first.timeline.items.sparseOverrideCount == 1)

        snapshot.toolExecutions[1] = updatedTool(snapshot.toolExecutions[1], output: "two")
        let second = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: first,
            canonicalSourceUnchanged: true
        )
        #expect(second.timeline.items.sparseOverrideCount == 2)
        #expect(second.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)

        snapshot.phase = .idle
        let assembled = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: second,
            canonicalSourceUnchanged: true
        )
        #expect(assembled.workReport.mode != .toolPayloadPatch)
        #expect(assembled.timeline.items.sparseOverrideCount == 0)
        #expect(assembled.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
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

    private func updatedTool(
        _ tool: ToolExecutionState,
        status: ToolExecutionState.Status? = nil,
        order: Int? = nil,
        output: String? = nil,
        startedAt: String? = nil
    ) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: tool.toolCallId,
            toolName: tool.toolName,
            order: order ?? tool.order,
            status: status ?? tool.status,
            arguments: tool.arguments,
            partialResult: tool.partialResult,
            result: tool.result,
            output: output ?? tool.output,
            outputTruncated: tool.outputTruncated,
            isError: tool.isError,
            startedAt: startedAt ?? tool.startedAt,
            updatedAt: "2026-01-01T00:00:01Z",
            lastProgressAt: "2026-01-01T00:00:01Z",
            completedAt: status == .completed ? "2026-01-01T00:00:01Z" : tool.completedAt,
            durationMs: tool.durationMs,
            progressSequence: (tool.progressSequence ?? 0) + 1
        )
    }

    private func transcriptItem(
        id: String,
        text: String,
        role: String = "user"
    ) throws -> TranscriptItem {
        try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"\(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"\(role)","content":[{"id":"\(id)-text","type":"text","text":"\(text)"}]}
        """.utf8))
    }

    private func fixture(transcript: String) throws -> SessionSnapshot {
        try decodeTranscriptFixture(SessionSnapshot.self, from: Data("""
        {
          "sessionId":"session","runtimeGeneration":"generation","revision":1,"eventSequence":1,"phase":"idle","cwd":"/workspace",
          "model":{"provider":"test","id":"model"},"thinkingLevel":"high","availableThinkingLevels":["off","high"],
          "stats":{"userMessages":0,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0},
          "queued":{"steering":[],"followUp":[]},"transcript":\(transcript),"transcriptStart":0,"transcriptTotal":0,
          "toolExecutions":[],"extensionPresentation":{"version":2,"hostEpoch":"host","revision":0,"capabilities":[],"diagnostics":[],"semanticState":{"statuses":{},"working":{"visible":false},"widgets":[],"toolsExpanded":false,"editorRevision":0,"editorText":""},"surfaces":[],"pendingInteractions":[]},"diagnostics":[]
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
