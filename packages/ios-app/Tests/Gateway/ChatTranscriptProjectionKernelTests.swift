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
            "assistant", "tool-run-call", "assistant-slice-content-2", "bash",
            "notification-compaction-slot-4", "streaming-source",
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

    @Test("display tools remain isolated from adjacent generic tool runs")
    func displayRunIsolation() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"presentationId":"assistant","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"read","ordinal":0,"type":"toolCall","toolCallId":"read-call","name":"read","arguments":{}},
            {"id":"display","ordinal":1,"type":"toolCall","toolCallId":"display-call","name":"display","arguments":{"presentation":{"surface":"inline"}}},
            {"id":"write","ordinal":2,"type":"toolCall","toolCallId":"write-call","name":"write","arguments":{}}
          ]},
          {"id":"display-result","parentId":"assistant","presentationId":"display-result","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"text","ordinal":0,"type":"text","text":"Displayed."}],"toolCallId":"display-call","toolName":"display","isError":false,
           "display":{"schema":"tron.display.v1","displayId":"display-id","revision":1,"title":"Preview","altText":"Preview image.","kind":"image","presentation":{"requestedSurface":"inline","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Preview image.","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b","name":"preview.png","mimeType":"image/png","size":128,"kind":"image"}}}
        ]
        """)
        let projection = ChatTranscriptProjectionKernel.readOnlyTranscript(
            snapshot.transcript,
            transcriptStart: 0,
            transcriptTotal: snapshot.transcript.count,
            isActive: true
        )
        let runs = projection.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.map { $0.tools.map(\.id) } == [["read-call"], ["display-call"], ["write-call"]])
        #expect(runs[1].tools.first?.display?.displayId == "display-id")
        #expect(projection.isValid)
    }

    @Test("read-only child transcript uses canonical tool and message assembly")
    func readOnlyChildAssembly() async throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"presentationId":"assistant","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking","ordinal":0,"thinkingRunOrdinal":0,"type":"thinking","text":"**Checking** the file"},
            {"id":"call","ordinal":1,"type":"toolCall","toolCallId":"read-call","name":"read","arguments":{"path":"README.md"}},
            {"id":"answer","ordinal":2,"type":"text","text":"## Finished\\nThe file is ready."}
          ]},
          {"id":"result","parentId":"assistant","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","ordinal":0,"type":"text","text":"contents"}],"toolCallId":"read-call","toolName":"read","isError":false}
        ]
        """)

        let projection = ChatTranscriptProjectionKernel.readOnlyTranscript(
            snapshot.transcript,
            transcriptStart: 0,
            transcriptTotal: snapshot.transcript.count,
            isActive: false
        )

        #expect(projection.isValid)
        #expect(projection.timeline.ids == [
            "assistant", "tool-run-read-call", "assistant-slice-content-2",
        ])
        let runs = projection.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.tools.map(\.id) == ["read-call"])
        #expect(run.tools.first?.subtitle == "Completed")
        let tool = try #require(run.tools.first.flatMap(projection.toolPayloads.resolving))
        #expect(tool.request == .object(["path": .string("README.md")]))
        #expect(tool.content == "contents")

        let messages = projection.timeline.items.compactMap { item -> ChatMessagePresentation? in
            guard case .message(let message) = item else { return nil }
            return message
        }
        #expect(messages.count == 2)
        #expect(messages.contains { message in
            message.parts.contains { part in
                guard case .content(let content) = part else { return false }
                return content.type == .text && content.text?.contains("The file is ready") == true
            }
        })

        let cache = ChatTextPreparationCache()
        let prepared = await cache.prepare(ChatTextPreparationPolicy.sources(in: snapshot.transcript))
        let slices = messages.map { prepared.slice(for: .message($0)) }
        #expect(slices.contains { !$0.thinking.isEmpty })
        #expect(slices.contains { !$0.markdown.isEmpty })
        #expect(slices.flatMap(\.thinking.values).allSatisfy {
            $0.inline.attributedString != nil
        })
    }

    @Test("read-only unresolved invocation follows authoritative child activity")
    func readOnlyInvocationLifecycle() throws {
        let snapshot = try fixture(transcript: """
        [{"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call","ordinal":0,"type":"toolCall","toolCallId":"call","name":"read","arguments":{}}]}]
        """)
        let active = ChatTranscriptProjectionKernel.readOnlyTranscript(
            snapshot.transcript,
            transcriptStart: 0,
            transcriptTotal: 1,
            isActive: true
        )
        let inactive = ChatTranscriptProjectionKernel.readOnlyTranscript(
            snapshot.transcript,
            transcriptStart: 0,
            transcriptTotal: 1,
            isActive: false
        )
        guard case .toolRun(let activeRun) = active.timeline.items.first,
              case .toolRun(let inactiveRun) = inactive.timeline.items.first else {
            Issue.record("Expected one projected tool run")
            return
        }
        #expect(activeRun.tools.first?.subtitle == "Invocation")
        #expect(activeRun.tools.first?.isRunning == true)
        #expect(inactiveRun.tools.first?.subtitle == "Interrupted")
        #expect(inactiveRun.tools.first?.error == true)
    }

    @Test("read-only child activity applies only to its newest canonical tool segment")
    func readOnlyChildUsesCanonicalToolSegmentAuthority() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"old-user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"old-text","ordinal":0,"type":"text","text":"old"}]},
          {"id":"old-assistant","parentId":"old-user","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"old-call","ordinal":0,"type":"toolCall","toolCallId":"old-call","name":"bash","arguments":{},"toolSegmentId":"old-segment"}]},
          {"id":"new-user","parentId":"old-assistant","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"new-text","ordinal":0,"type":"text","text":"new"}]}
        ]
        """)
        var projection = ChatTranscriptProjectionKernel.readOnlyTranscript(
            snapshot.transcript,
            transcriptStart: 0,
            transcriptTotal: snapshot.transcript.count,
            isActive: true
        )
        guard let oldRun = projection.timeline.items.compactMap({ item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }).first else {
            Issue.record("Expected the retained old tool run")
            return
        }
        #expect(oldRun.tools.first?.subtitle == "Interrupted")

        snapshot.transcript.append(try decodeTranscriptFixture(
            TranscriptItem.self,
            from: Data("""
            {"id":"new-assistant","parentId":"new-user","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"assistant","content":[{"id":"new-call","ordinal":0,"type":"toolCall","toolCallId":"new-call","name":"read","arguments":{},"toolSegmentId":"new-segment"},{"id":"new-status","ordinal":1,"type":"text","text":"Working"}]}
            """.utf8)
        ))
        projection = ChatTranscriptProjectionKernel.readOnlyTranscript(
            snapshot.transcript,
            transcriptStart: 0,
            transcriptTotal: snapshot.transcript.count,
            isActive: true
        )
        let runs = projection.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.count == 2)
        #expect(runs[0].tools.first?.subtitle == "Interrupted")
        #expect(runs[1].tools.first?.subtitle == "Invocation")
    }

    @Test("a new operation cannot reactivate an interrupted invocation from an older run")
    func newOperationDoesNotReactivateInterruptedInvocation() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"old-user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"old-text","type":"text","text":"start"}]},
          {"id":"old-assistant","parentId":"old-user","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"old-call","type":"toolCall","toolCallId":"old-call","name":"bash","arguments":{"command":"sleep 30"},"toolSegmentId":"old-segment"}]}
        ]
        """)
        snapshot.transcriptTotal = snapshot.transcript.count
        snapshot.phase = .interrupted
        let stopped = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let stoppedRun) = stopped.timeline.items.last else {
            Issue.record("Expected the stopped tool run")
            return
        }
        #expect(stoppedRun.tools.first?.subtitle == "Interrupted")

        // Pi emits agent_start before the new canonical user message. That phase
        // change must not make the older unresolved call look live again.
        snapshot.phase = .running
        snapshot.acceptsQueuedPrompts = true
        snapshot.activeToolSegmentId = "new-segment"
        snapshot.operation = SessionOperationState(
            id: "new-operation",
            kind: .prompt,
            startedAt: "2026-01-01T00:00:10Z"
        )
        let restarted = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: stopped,
            canonicalSourceUnchanged: true
        )
        guard case .toolRun(let restartedRun) = restarted.timeline.items.last else {
            Issue.record("Expected the retained stopped tool run")
            return
        }
        #expect(restartedRun.tools.first?.subtitle == "Interrupted")
        #expect(!restartedRun.isRunning)
        #expect(restarted.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)

        var cached = snapshot
        cached.isCachedProjection = true
        let cachedCandidate = ChatTranscriptProjectionKernel.cold(snapshot: cached)
        guard case .toolRun(let cachedRun) = cachedCandidate.timeline.items.last else {
            Issue.record("Expected the cached tool run")
            return
        }
        #expect(cachedRun.tools.first?.subtitle == "Invocation")
        #expect(cachedRun.isRunning)

        for (phase, acceptsQueuedPrompts) in [
            (SessionPhase.running, false),
            (.compacting, true),
            (.retrying, true),
        ] {
            var noAgentRun = snapshot
            noAgentRun.phase = phase
            noAgentRun.acceptsQueuedPrompts = acceptsQueuedPrompts
            noAgentRun.activeToolSegmentId = nil
            let candidate = ChatTranscriptProjectionKernel.cold(snapshot: noAgentRun)
            guard case .toolRun(let run) = candidate.timeline.items.last else {
                Issue.record("Expected the retained tool run without a foreground agent")
                continue
            }
            #expect(run.tools.first?.subtitle == "Interrupted")
        }

        var legacyCompaction = snapshot
        legacyCompaction.phase = .compacting
        legacyCompaction.acceptsQueuedPrompts = nil
        legacyCompaction.activeToolSegmentId = nil
        let legacyCandidate = ChatTranscriptProjectionKernel.cold(snapshot: legacyCompaction)
        guard case .toolRun(let legacyRun) = legacyCandidate.timeline.items.last else {
            Issue.record("Expected the legacy active-phase tool run")
            return
        }
        #expect(legacyRun.tools.first?.subtitle == "Invocation")

        // A declaration produced after the new operation starts remains a live
        // Invocation while it waits behind another sequential call.
        snapshot.transcript.append(contentsOf: try decodeTranscriptFixture(
            [TranscriptItem].self,
            from: Data("""
            [
              {"id":"new-user","parentId":"old-assistant","timestamp":"2026-01-01T00:00:10Z","kind":"message","role":"user","content":[{"id":"new-text","type":"text","text":"continue"}]},
              {"id":"new-assistant","parentId":"new-user","timestamp":"2026-01-01T00:00:11Z","kind":"message","role":"assistant","content":[{"id":"new-call","type":"toolCall","toolCallId":"new-call","name":"read","arguments":{"path":"README.md"},"toolSegmentId":"new-segment"}]}
            ]
            """.utf8)
        ))
        snapshot.transcriptTotal = snapshot.transcript.count
        let current = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let runs = current.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.count == 2)
        #expect(runs[0].tools.first?.subtitle == "Interrupted")
        #expect(runs[1].tools.first?.subtitle == "Invocation")
        #expect(runs[1].isRunning)
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

    @Test("canonical tool settlement owns matching streaming presentation")
    func canonicalToolSettlementOwnsStreamingOverlap() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"canonical","parentId":null,"presentationId":"stream:settlement","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"canonical-call","ordinal":0,"type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"README.md"},"groupId":"group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}]
        """)
        snapshot.transcriptTotal = 1
        snapshot.phase = .running
        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"streaming","parentId":null,"presentationId":"stream:settlement","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"streaming-call","ordinal":0,"type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"README.md"},"groupId":"group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
        """.utf8))

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        #expect(candidate.timeline.ids == ["tool-run-group"])
        #expect(Set(candidate.timeline.ids).count == candidate.timeline.ids.count)
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected one canonically owned tool run")
            return
        }
        #expect(run.tools.map(\.id) == ["call"])
        #expect(candidate.isValid)
    }

    @Test("exact canonical tool membership owns stale streaming identity during settlement")
    func canonicalToolMembershipOwnsRotatedStreamingOverlap() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"canonical","parentId":null,"presentationId":"canonical:settlement","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"canonical-call","ordinal":0,"type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"README.md"},"groupId":"canonical-group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}]
        """)
        snapshot.transcriptTotal = 1
        snapshot.phase = .running
        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"streaming","parentId":null,"presentationId":"stream:rotated","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"streaming-text","ordinal":0,"type":"text","text":"stale frame"},{"id":"streaming-call","ordinal":1,"type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"README.md"},"groupId":"stale-group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
        """.utf8))

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        #expect(candidate.timeline.ids == ["tool-run-canonical-group"])
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected canonical tool ownership")
            return
        }
        #expect(run.tools.map(\.id) == ["call"])
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

    @Test("100 and 256 legacy unanchored tools fail closed to distinct deterministic rows", arguments: [100, 256])
    func largeToolBursts(count: Int) throws {
        let builder = SessionScenarioBuilder(seed: 1_301 + count)
        var snapshot = try builder.openingTail(targetEncodedBytes: 8_000)
        snapshot.transcript = []
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 0
        snapshot.phase = .running
        snapshot.toolExecutions = Array(builder.liveToolBurst(count: count).reversed())

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let runs = candidate.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.count == count)
        #expect(runs.allSatisfy { $0.tools.count == 1 })
        #expect(runs.flatMap(\.tools).map(\.id) == builder.liveToolBurst(count: count).map(\.toolCallId))
        #expect(candidate.workReport.toolsInspected == count)
        #expect(candidate.isValid)
    }

    @Test("duplicate runtime identities resolve newest while legacy calls stay separate")
    func duplicateToolOrderAndReplacement() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [
            runtimeTool(id: "duplicate", order: 0, output: "older"),
            runtimeTool(id: "between", order: 1, output: "middle"),
            runtimeTool(id: "duplicate", order: 2, output: "newest"),
        ]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let runs = candidate.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.map { $0.tools.map(\.id) } == [["between"], ["duplicate"]])
        #expect(runs.flatMap(\.tools).compactMap(candidate.toolPayloads.resolving).map(\.content) == ["middle", "newest"])
        #expect(candidate.timeline.renderedIDBySemanticID["duplicate"] == "tool-run-duplicate")
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

    @Test("adjacent canonical groups compact without losing exact membership")
    func sequentialToolMessagesShareDisplayRun() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.transcript = try (0..<15).map { index in
            try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"assistant-\(index)","parentId":null,"presentationId":"turn-\(index)","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"part-\(index)","ordinal":0,"type":"toolCall","toolCallId":"call-\(index)","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn-0","groupId":"group-\(index)","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8))
        }
        snapshot.transcriptTotal = snapshot.transcript.count

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected one adjacent canonical display run")
            return
        }
        #expect(candidate.fragments.count == 15)
        #expect(candidate.timeline.items.count == 1)
        #expect(run.id == "tool-run-group-0")
        #expect(run.groupIDs == (0..<15).map { "group-\($0)" })
        #expect(run.tools.map(\.id) == (0..<15).map { "call-\($0)" })
        #expect(run.displayCount == 15)
        #expect(run.title == "15 tools")
        #expect(candidate.toolPayloads.callIDs == Set((0..<15).map { "call-\($0)" }))
        #expect(candidate.isValid)
    }

    @Test("adjacent groups from different producer segments remain separate")
    func producerSegmentsDoNotCrossTurns() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant-a","parentId":null,"presentationId":"assistant-a","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"part-a","ordinal":0,"type":"toolCall","toolCallId":"call-a","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn-a","groupId":"group-a","groupIndex":0,"groupCount":1,"groupFinalized":true}]},
          {"id":"assistant-b","parentId":"assistant-a","presentationId":"assistant-b","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"part-b","ordinal":0,"type":"toolCall","toolCallId":"call-b","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn-b","groupId":"group-b","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
        ]
        """)
        snapshot.transcriptTotal = 2

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let runs = candidate.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.map(\.id) == ["tool-run-group-a", "tool-run-group-b"])
        #expect(runs.map { $0.tools.map(\.id) } == [["call-a"], ["call-b"]])
        #expect(candidate.isValid)
    }

    @Test("matching producer segments never merge canonical and runtime ownership")
    func producerSegmentDoesNotCrossOwnershipRegions() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"canonical-part","type":"toolCall","toolCallId":"canonical-call","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn","groupId":"canonical-group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.transcriptTotal = 1
        snapshot.toolExecutions = [runtimeTool(
            id: "runtime-call", order: 1, toolSegmentId: "tool-segment:turn"
        )]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let canonicalTools = candidate.timeline.items.canonical.compactMap { item -> [String]? in
            guard case .toolRun(let run) = item else { return nil }
            return run.tools.map(\.id)
        }
        let liveTools = candidate.timeline.items.live.compactMap { item -> [String]? in
            guard case .toolRun(let run) = item else { return nil }
            return run.tools.map(\.id)
        }

        #expect(canonicalTools == [["canonical-call"]])
        #expect(liveTools == [["runtime-call"]])
        #expect(candidate.isValid)

        guard case .toolRun(let canonicalRun) = candidate.timeline.items.canonical.first,
              case .toolRun(let liveRun) = candidate.timeline.items.live.first,
              let fused = ChatPhysicalToolRunFusion(canonical: canonicalRun, live: liveRun) else {
            Issue.record("Expected an admitted display-only canonical/live fusion")
            return
        }
        #expect(fused.run.id == canonicalRun.id)
        #expect(fused.run.tools.map(\.id) == ["canonical-call", "runtime-call"])
        #expect(fused.run.isRunning)
    }

    @Test("matching finalized group IDs across canonical and live stay valid and compose physically")
    func sameGroupCrossOwnerComposition() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"canonical-part","type":"toolCall","toolCallId":"canonical-call","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn","groupId":"shared-group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.transcriptTotal = 1
        snapshot.toolExecutions = [groupedRuntimeTool(
            id: "live-call", index: 0, count: 1, status: .running,
            groupID: "shared-group", order: 1
        )]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.isValid)
        guard case .toolRun(let canonical) = candidate.timeline.items.canonical.first,
              case .toolRun(let live) = candidate.timeline.items.live.first,
              let fusion = ChatPhysicalToolRunFusion(canonical: canonical, live: live) else {
            Issue.record("Expected separate valid owners and one display composition")
            return
        }
        #expect(canonical.id == "tool-run-shared-group")
        #expect(live.id == "tool-run-shared-group#live")
        #expect(fusion.run.id == canonical.id)
        #expect(fusion.run.tools.map(\.id) == ["canonical-call", "live-call"])
        #expect(fusion.run.isRunning)
    }

    @Test("display-only tool fusion fails closed for missing or conflicting segments")
    func displayToolFusionRequiresOneNonemptySegment() throws {
        let canonical = ChatToolRunPresentation(tools: [descriptor(
            id: "canonical", segment: "segment-a", subtitle: "Used"
        )])
        let missing = ChatToolRunPresentation(tools: [descriptor(
            id: "missing", segment: nil, subtitle: "Running"
        )])
        let conflicting = ChatToolRunPresentation(tools: [descriptor(
            id: "conflicting", segment: "segment-b", subtitle: "Running"
        )])
        #expect(ChatPhysicalToolRunFusion(canonical: canonical, live: missing) == nil)
        #expect(ChatPhysicalToolRunFusion(canonical: canonical, live: conflicting) == nil)
    }

    @Test("foreground catch-up replaces one immutable ledger value without adding physical rows")
    func foregroundCatchUpPreservesCommittedLedgerIntegrity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.transcript = [try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"assistant-0","parentId":null,"presentationId":"turn-0","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"part-0","ordinal":0,"type":"toolCall","toolCallId":"call-0","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn-0","groupId":"group-0","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
        """.utf8))]
        snapshot.transcriptTotal = 1

        let before = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let frozen = ChatCommittedLedger(items: before.timeline.items.canonical)
        #expect(before.timeline.ids == ["tool-run-group-0"])

        snapshot.transcript.append(contentsOf: try (1..<15).map { index in
            try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"assistant-\(index)","parentId":null,"presentationId":"turn-\(index)","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"part-\(index)","ordinal":0,"type":"toolCall","toolCallId":"call-\(index)","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn-0","groupId":"group-\(index)","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8))
        })
        snapshot.transcriptTotal = snapshot.transcript.count
        snapshot.eventSequence += 1
        let caughtUp = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: before,
            canonicalSourceUnchanged: false
        )
        let installed = ChatCommittedLedger.reconcile(
            items: caughtUp.timeline.items.canonical,
            previous: frozen
        )

        guard case .toolRun(let frozenRun) = frozen.items.first,
              case .toolRun(let installedRun) = installed.items.first else {
            Issue.record("Expected one immutable display run in both ledger values")
            return
        }
        #expect(frozen.revision == 1)
        #expect(frozenRun.tools.map(\.id) == ["call-0"])
        #expect(installed.revision == 2)
        #expect(installed.items.count == 1)
        #expect(installedRun.id == frozenRun.id)
        #expect(installedRun.tools.map(\.id) == (0..<15).map { "call-\($0)" })
        #expect(caughtUp.timeline.ids == before.timeline.ids)
        #expect(caughtUp.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
        #expect(caughtUp.isValid)
    }

    @Test("retained runtime groups compact under the first exact group identity")
    func runtimeGroupsShareDisplayRun() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = (0..<15).map { index in
            groupedRuntimeTool(
                id: "runtime-\(index)",
                index: 0,
                count: 1,
                status: index == 14 ? .running : .completed,
                groupID: "runtime-group-\(index)",
                order: index
            )
        }

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected one retained runtime display run")
            return
        }
        #expect(candidate.timeline.items.count == 1)
        #expect(run.id == "tool-run-runtime-group-0")
        #expect(run.tools.map(\.id) == (0..<15).map { "runtime-\($0)" })
        #expect(run.groupIDs == (0..<15).map { "runtime-group-\($0)" })
        #expect(run.displayCount == 15)
        #expect(run.title == "15 tools")
        #expect(candidate.isValid)
    }

    @Test("duplicate exact IDs in finalized group slots remain invalid instead of being filtered")
    func duplicateFinalizedGroupIDsFailClosed() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.transcript = [
            try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"assistant-one","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"part-one","ordinal":0,"type":"toolCall","toolCallId":"duplicate","name":"read","arguments":{},"groupId":"group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8)),
            try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"assistant-two","parentId":"assistant-one","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"part-two","ordinal":0,"type":"toolCall","toolCallId":"duplicate","name":"read","arguments":{},"groupId":"group","groupIndex":0,"groupCount":1,"groupFinalized":true}]}
            """.utf8)),
        ]
        snapshot.transcriptTotal = 2

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let tools = candidate.timeline.items.compactMap { item -> [ChatToolDescriptor]? in
            guard case .toolRun(let run) = item else { return nil }
            return run.tools
        }.flatMap { $0 }
        #expect(tools.map(\.id) == ["duplicate", "duplicate"])
        #expect(!candidate.isValid)
    }

    @Test("finalized streaming and runtime siblings form one exact producer-ordered group")
    func finalizedStreamingRuntimeGroupContinuity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
          {"id":"call-one-part","ordinal":0,"type":"toolCall","toolCallId":"call-one","name":"read","arguments":{}}
        ]}
        """.utf8))
        snapshot.toolExecutions = [
            groupedRuntimeTool(id: "call-two", index: 1, count: 2, status: .running),
            groupedRuntimeTool(id: "call-one", index: 0, count: 2, status: .completed),
        ]

        let cold = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: ChatTranscriptProjectionKernel.cold(snapshot: try fixture(transcript: "[]")),
            canonicalSourceUnchanged: false
        )
        let runs = cold.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.count == 1)
        #expect(runs[0].tools.map(\.id) == ["call-one", "call-two"])
        #expect(runs[0].isRunning)
        #expect(Set(runs[0].tools.map(\.id)).count == 2)
        #expect(cold.timeline.renderedIDBySemanticID["call-one"] == "tool-run-group")
        #expect(cold.timeline.renderedIDBySemanticID["call-two"] == "tool-run-group")
        #expect(incremental.timeline == cold.timeline)
        #expect(incremental.toolPayloads == cold.toolPayloads)
        #expect(cold.isValid)
    }

    @Test("canonical takeover keeps mixed terminal siblings atomic until runtime retirement")
    func canonicalGroupTakeoverAndRetirement() throws {
        var runtime = try fixture(transcript: "[]")
        runtime.phase = .running
        runtime.toolExecutions = [
            groupedRuntimeTool(id: "call-two", index: 1, count: 2, status: .failed),
            groupedRuntimeTool(id: "call-one", index: 0, count: 2, status: .completed),
        ]
        let runtimeCandidate = ChatTranscriptProjectionKernel.cold(snapshot: runtime)

        var canonical = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"call-one-part","ordinal":0,"type":"toolCall","toolCallId":"call-one","name":"read","arguments":{},"groupId":"group","groupIndex":0,"groupCount":2,"groupFinalized":true},
            {"id":"call-two-part","ordinal":1,"type":"toolCall","toolCallId":"call-two","name":"read","arguments":{},"groupId":"group","groupIndex":1,"groupCount":2,"groupFinalized":true}
          ]}
        ]
        """)
        canonical.transcriptTotal = canonical.transcript.count
        canonical.phase = .idle
        canonical.toolExecutions = runtime.toolExecutions
        let takeover = ChatTranscriptProjectionKernel.incremental(
            snapshot: canonical,
            previous: runtimeCandidate,
            canonicalSourceUnchanged: false
        )
        guard case .toolRun(let mixedRun) = takeover.timeline.items.first else {
            Issue.record("Expected one canonical group")
            return
        }
        #expect(takeover.timeline.items.count == 1)
        #expect(mixedRun.tools.map(\.id) == ["call-one", "call-two"])
        #expect(mixedRun.failureCount == 1)
        #expect(!mixedRun.isRunning)
        #expect(takeover.timeline == ChatTranscriptProjectionKernel.cold(snapshot: canonical).timeline)
        #expect(takeover.isValid)

        canonical.toolExecutions = []
        let retired = ChatTranscriptProjectionKernel.incremental(
            snapshot: canonical,
            previous: takeover,
            canonicalSourceUnchanged: true
        )
        guard case .toolRun(let canonicalRun) = retired.timeline.items.first else {
            Issue.record("Expected canonical group after runtime retirement")
            return
        }
        #expect(canonicalRun.tools.map(\.id) == ["call-one", "call-two"])
        #expect(Set(canonicalRun.tools.map(\.id)).count == 2)
        #expect(retired.timeline == ChatTranscriptProjectionKernel.cold(snapshot: canonical).timeline)
        #expect(retired.isValid)
    }

    @Test("a visible barrier prevents unsafe finalized-group relocation")
    func finalizedGroupBarrierFailsClosed() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"call-one-part","ordinal":0,"type":"toolCall","toolCallId":"call-one","name":"read","arguments":{}}
          ]},
          {"id":"user","parentId":"assistant","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","content":[{"id":"text","ordinal":0,"type":"text","text":"barrier"}]}
        ]
        """)
        snapshot.transcriptTotal = snapshot.transcript.count
        snapshot.phase = .running
        snapshot.toolExecutions = [
            groupedRuntimeTool(id: "call-one", index: 0, count: 2, status: .completed),
            groupedRuntimeTool(id: "call-two", index: 1, count: 2, status: .running),
        ]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let runs = candidate.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.count == 2)
        #expect(runs.flatMap(\.tools).map(\.id) == ["call-one", "call-two"])
        #expect(candidate.timeline.items.contains { item in
            if case .message(let message) = item { return message.item.id == "user" }
            return false
        })
        #expect(!candidate.isValid)
    }

    @Test("streaming anchors and unanchored runtime calls share one ordered tail run")
    func streamingAndUnanchoredTools() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Working"},
          {"id":"call-part","type":"toolCall","toolCallId":"anchored","name":"read","arguments":{},"toolSegmentId":"tool-segment:turn"}
        ]}
        """.utf8))
        snapshot.toolExecutions = [
            runtimeTool(id: "unanchored", order: 1, toolSegmentId: "tool-segment:turn"),
            runtimeTool(id: "anchored", order: 0, toolSegmentId: "tool-segment:turn"),
        ]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.ids == ["streaming", "tool-run-anchored"])
        let runs = candidate.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.map { $0.tools.map(\.id) } == [["anchored", "unanchored"]])
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
        [{"id":"result","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"toolResult","content":[{"id":"text","type":"text","text":"done"}],"toolCallId":"extension-call","toolName":"subagent","toolLabel":"Subagent","isError":false,"extensionOrigin":{"source":"pi-subagents"}}]
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
        #expect(tool.toolName == "subagent")
        #expect(tool.title == "Subagent")
    }

    @Test("triggered extension messages remain trailing conversation input instead of tool runs")
    func triggeredExtensionMessageIsConversationInput() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"notice","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"customMessage","customType":"subagent-notify","content":[{"id":"text","ordinal":0,"type":"text","text":"Background worker finished"}],"details":{"runId":"run-1"},"semantic":{"version":1,"direction":"inboundContext","contextEffect":"modelInput","delivery":"triggeredTurn","visibility":"visible","kind":"message","origin":{"kind":"subagent","ownerId":"extension:opaque","title":"Pi Subagents","confidence":"receipt"},"sequence":0}}]
        """)
        snapshot.transcriptTotal = 1

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.items.count == 1)
        guard case .transcript(let item) = candidate.timeline.items.first else {
            Issue.record("Expected a session-input transcript row")
            return
        }
        #expect(item.id == "notice")
        #expect(item.text == "Background worker finished")
        #expect(item.semantic?.delivery == .triggeredTurn)
        #expect(item.semantic?.origin.title == "Pi Subagents")
        #expect(candidate.toolPayloads.callIDs.isEmpty)
    }

    @Test("canonical command receipts remain ordered transcript rows rather than user or tool rows")
    func commandReceiptIsDedicatedTranscriptRow() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"command","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"customEntry","customType":"tron.chat-invocation.v1","semantic":{"version":1,"direction":"ambientStatus","contextEffect":"none","delivery":"stored","visibility":"visible","kind":"command","origin":{"kind":"extension","ownerId":"extension:goal","title":"Pi Goal","confidence":"adapter"},"invocationId":"invocation","operationId":"operation","sequence":1,"lifecycle":"running","resourceInvocation":{"source":"extension","name":"goal","arguments":"count to 20"}}}]
        """)
        snapshot.transcriptTotal = 1

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.items.count == 1)
        guard case .transcript(let item) = candidate.timeline.items.first else {
            Issue.record("Expected a dedicated canonical command row")
            return
        }
        #expect(item.id == "command")
        #expect(item.semantic?.kind == .command)
        #expect(item.semantic?.direction == .ambientStatus)
        #expect(item.semantic?.resourceInvocation == ComposerResourceInvocation(
            source: .extension, name: "goal", arguments: "count to 20"
        ))
        #expect(candidate.toolPayloads.callIDs.isEmpty)
    }

    @Test("canonical extension notifications are centered status rows rather than app notices")
    func extensionNotificationIsCanonicalStatus() throws {
        var snapshot = try fixture(transcript: """
        [{"id":"notice","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"customEntry","customType":"tron.extension-notification.v1","data":{"writer":"gateway","version":1,"receiptId":"notification:goal","sessionId":"session","message":"Goal created.","tone":"info","origin":{"kind":"extension","ownerId":"extension:goal","title":"Pi Goal","confidence":"receipt"},"sequence":1,"createdAt":"2026-01-01T00:00:00.000Z"},"semantic":{"version":1,"direction":"ambientStatus","contextEffect":"none","delivery":"stored","visibility":"visible","kind":"status","origin":{"kind":"extension","ownerId":"extension:goal","title":"Pi Goal","confidence":"receipt"},"sequence":1}}]
        """)
        snapshot.transcriptTotal = 1

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(candidate.timeline.items.count == 1)
        guard case .notification(let notice) = candidate.timeline.items.first else {
            Issue.record("Expected a centered extension notification")
            return
        }
        #expect(notice.title == "Pi Goal · Notification")
        #expect(notice.detail == "Info")
        #expect(notice.body == "Goal created.")
        #expect(notice.tone == .information)
        #expect(notice.material == .glass)
        #expect(candidate.toolPayloads.callIDs.isEmpty)
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

    @Test("duplicate canonical IDs fail admission and prevent sparse tool patching")
    func duplicateCanonicalIDsFailAdmission() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"bash","command":"one","output":"","cancelled":false,"truncated":false},
          {"id":"duplicate","parentId":"duplicate","timestamp":"2026-01-01T00:00:01Z","kind":"bash","command":"two","output":"","cancelled":false,"truncated":false}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [runtimeTool(id: "live", order: 0, output: "old")]
        let previous = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(previous.timeline.ids == ["duplicate", "duplicate", "tool-run-live"])
        #expect(!previous.isValid)

        snapshot.toolExecutions = [updatedTool(snapshot.toolExecutions[0], output: "new")]
        let incremental = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: previous,
            canonicalSourceUnchanged: true
        )
        #expect(incremental.workReport.mode != .toolPayloadPatch)
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
        #expect(completedIDs == ["user", "stream", "tool-run-one"])
        let flipped = ChatTranscriptProjectionKernel.incremental(
            snapshot: placement,
            previous: completed,
            canonicalSourceUnchanged: true
        )
        #expect(flipped.workReport.mode == .toolPayloadPatch)
        #expect(flipped.timeline.ids == ["user", "stream", "tool-run-one"])
        #expect(flipped.timeline == ChatTranscriptProjectionKernel.cold(snapshot: placement).timeline)
    }

    @Test("live payload changes do not advance committed structural revision")
    func livePayloadPatchPreservesCommittedRevision() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"part","type":"toolCall","toolCallId":"call","name":"read","arguments":{}}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.transcriptTotal = 1
        snapshot.toolExecutions = [runtimeTool(id: "call", order: 0)]
        let running = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let initialLedger = ChatCommittedLedger(items: running.timeline.items.canonical)

        snapshot.toolExecutions = [updatedTool(
            snapshot.toolExecutions[0], status: .completed, output: "done"
        )]
        let completed = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: running,
            canonicalSourceUnchanged: true
        )
        let reconciled = ChatCommittedLedger.reconcile(
            items: completed.timeline.items.canonical,
            previous: initialLedger
        )

        #expect(reconciled.revision == initialLedger.revision)
        #expect(reconciled.items != initialLedger.items)
        #expect(completed.workReport.mode == .toolPayloadPatch)
    }

    @Test("one producer segment keeps one row through mixed terminal settlement")
    func segmentedRuntimeLifecycle() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [runtimeTool(
            id: "one", order: 0, toolSegmentId: "tool-segment:turn"
        )]
        let first = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        #expect(first.timeline.ids == ["tool-run-one"])

        snapshot.toolExecutions.append(runtimeTool(
            id: "two", order: 1, toolSegmentId: "tool-segment:turn"
        ))
        let second = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: first,
            canonicalSourceUnchanged: true
        )
        #expect(second.timeline.ids == ["tool-run-one"])

        snapshot.toolExecutions = [
            updatedTool(snapshot.toolExecutions[0], status: .completed, output: "done"),
            updatedTool(snapshot.toolExecutions[1], status: .failed, output: "failed"),
            runtimeTool(id: "three", order: 2, toolSegmentId: "tool-segment:turn"),
        ]
        let mixed = ChatTranscriptProjectionKernel.incremental(
            snapshot: snapshot,
            previous: second,
            canonicalSourceUnchanged: true
        )
        let runs = mixed.timeline.items.compactMap { item -> ChatToolRunPresentation? in
            guard case .toolRun(let run) = item else { return nil }
            return run
        }
        #expect(runs.map(\.id) == ["tool-run-one"])
        #expect(runs.first?.tools.map(\.id) == ["one", "two", "three"])
        #expect(runs.first?.isRunning == true)
        #expect(runs.first?.tools[1].subtitle == "Failed")
        #expect(mixed.timeline == ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline)
        #expect(mixed.isValid)
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

    @Test("terminal live metadata cannot erase canonical tool output")
    func terminalLiveMetadataPreservesCanonicalOutput() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"settled-call","name":"read","arguments":{"path":"README.md"}}]},
          {"id":"result","parentId":"assistant","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"canonical output"}],"toolCallId":"settled-call","toolName":"read","isError":false}
        ]
        """)
        snapshot.phase = .running
        snapshot.transcriptTotal = 2
        func terminalMetadata(output: String?) -> ToolExecutionState {
            ToolExecutionState(
                toolCallId: "settled-call",
                toolName: "read",
                order: 0,
                status: .completed,
                arguments: .object(["path": .string("README.md")]),
                partialResult: nil,
                result: nil,
                output: output,
                isError: false,
                startedAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:01Z",
                completedAt: "2026-01-01T00:00:01Z"
            )
        }

        for output in [nil, ""] as [String?] {
            snapshot.toolExecutions = [terminalMetadata(output: output)]
            let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
            guard case .toolRun(let run) = candidate.timeline.items.first else {
                Issue.record("Expected canonical tool run")
                return
            }
            let detail = try #require(run.tools.first.flatMap(candidate.toolPayloads.resolving))
            #expect(detail.subtitle == "Completed")
            #expect(detail.content == "canonical output")
            #expect(ToolDetailPresentation(tool: detail).readableResult == "canonical output")
            #expect(ToolTechnicalResultResolver.resolve(detail) == .string("canonical output"))
        }
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

        #expect(cold.timeline.ids == ["user", "stream-source", "tool-run-stream-call"])
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

        #expect(cold.timeline.ids == ["user", "stream-source"])
        #expect(coldWorker.timeline == cold.timeline)
        #expect(coldWorker.timeline.items.canonical.map(\.id) == ["user"])
        #expect(coldWorker.timeline.items.live.map(\.id) == ["stream-source"])
        #expect(incremental.timeline == cold.timeline)
        #expect(incremental.timeline.items.canonical.map(\.id) == ["user"])
        #expect(incremental.timeline.items.live.map(\.id) == ["stream-source"])
        #expect(incremental.workReport.mode == .fragmentReuse)
        #expect(ChatTranscriptProjectionKernel.visibleItems(in: snapshot).map(\.id) == ["user"])
        #expect(cold.timeline.renderedIDBySemanticID["extension-call"] == nil)
    }

    @Test("runtime-only tools remain live after a streaming message")
    func runtimeOnlyRowsRemainLiveAfterStreaming() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.streaming = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"text","type":"text","text":"still working"}]}
        """.utf8))
        snapshot.toolExecutions = [runtimeTool(id: "runtime-call", order: 0)]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)

        #expect(candidate.timeline.items.canonical.isEmpty)
        #expect(candidate.timeline.items.live.map(\.id) == ["streaming", "tool-run-runtime-call"])
        #expect(candidate.timeline.items.live.allSatisfy { !candidate.timeline.items.canonical.contains($0) })
        #expect(candidate.isValid)
    }

    @Test("partial finalized groups are terminal when every visible descriptor is terminal")
    func partialFinalizedGroupDoesNotSpin() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [groupedRuntimeTool(
            id: "partial-call", index: 1, count: 3, status: .completed,
            groupID: "partial-group", order: 0
        )]

        guard case .toolRun(let run) = ChatTranscriptProjectionKernel.cold(snapshot: snapshot).timeline.items.live.first else {
            Issue.record("Expected a live tool run")
            return
        }
        #expect(run.displayCount == 3)
        #expect(!run.isRunning)
        #expect(run.title == "3 tools")
        #expect(run.status == "Completed")
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

    private func descriptor(
        id: String,
        segment: String?,
        subtitle: String
    ) -> ChatToolDescriptor {
        ChatToolDescriptor(ChatToolPresentation(
            id: id,
            title: "Read file",
            subtitle: subtitle,
            request: .object([:]),
            response: nil,
            content: "",
            fallbackContent: nil,
            error: false,
            startedAt: nil,
            completedAt: nil,
            durationMs: nil,
            lastProgressAt: nil,
            progressSequence: nil,
            toolSegmentId: segment
        ))
    }

    private func runtimeTool(
        id: String,
        order: Int,
        output: String? = nil,
        toolSegmentId: String? = nil
    ) -> ToolExecutionState {
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
            progressSequence: 1,
            toolSegmentId: toolSegmentId
        )
    }

    private func groupedRuntimeTool(
        id: String,
        index: Int,
        count: Int,
        status: ToolExecutionState.Status,
        groupID: String = "group",
        order: Int? = nil,
        toolSegmentId: String = "tool-segment:turn"
    ) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: id,
            toolName: "read",
            order: order ?? (count - index),
            status: status,
            arguments: .object([:]),
            partialResult: status == .running ? .object(["progress": .number(Double(index))]) : nil,
            result: status == .completed ? .object(["ok": .bool(true)]) : nil,
            output: status == .failed ? "failed" : (status == .completed ? "done" : "running"),
            isError: status == .failed,
            startedAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:01Z",
            lastProgressAt: "2026-01-01T00:00:01Z",
            completedAt: status == .running ? nil : "2026-01-01T00:00:01Z",
            durationMs: status == .running ? nil : 1_000,
            progressSequence: status == .running ? 1 : 2,
            toolSegmentId: toolSegmentId,
            groupId: groupID,
            groupIndex: index,
            groupCount: count,
            groupFinalized: true
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
            progressSequence: (tool.progressSequence ?? 0) + 1,
            toolSegmentId: tool.toolSegmentId,
            groupId: tool.groupId,
            groupIndex: tool.groupIndex,
            groupCount: tool.groupCount,
            groupFinalized: tool.groupFinalized
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
          "queueRevision":0,"queuedItems":[],"automaticCompactionEnabled":true,"transcript":\(transcript),"transcriptStart":0,"transcriptTotal":0,
          "toolExecutions":[],"extensionPresentation":{"version":3,"hostEpoch":"host","revision":0,"capabilities":[],"diagnostics":[],"semanticState":{"statuses":{},"working":{"visible":false},"widgets":[],"toolsExpanded":false,"editorRevision":0,"editorText":""},"surfaces":[],"pendingInteractions":[]},"diagnostics":[]
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
