import Foundation
import Testing
@testable import TronMobile

@Suite("Chat transcript presentation")
struct ChatTranscriptPresentationTests {
    @Test("native visible edge is authoritative over independently settling inset fields")
    func nativeVisibleBottomDistance() {
        let geometry = ChatTranscriptGeometry(
            offsetY: 400,
            contentHeight: 1_000,
            containerHeight: 400,
            bottomInset: 200,
            visibleBottomY: 1_200
        )

        #expect(geometry.distanceFromBottom == 0)
        #expect(geometry.isAtCatchUpBoundary)
    }

    @Test("retired subagent chrome is hidden while unrelated extension widgets remain")
    func retiredSubagentWidgetPolicy() {
        let widgets = [
            ExtensionWidget(key: "subagent-async", lines: ["1 active agent"], placement: .belowEditor),
            ExtensionWidget(key: "subagent-fleet-status", lines: ["Fleet"], placement: .aboveEditor),
            ExtensionWidget(key: "subagent-custom", lines: ["Keep"], placement: .belowEditor),
            ExtensionWidget(key: "project-status", lines: ["Ready"], placement: .aboveEditor),
        ]

        #expect(ChatExtensionWidgetPolicy.visibleWidgets(widgets, placement: .aboveEditor).map(\.key) == [
            "project-status",
        ])
        #expect(ChatExtensionWidgetPolicy.visibleWidgets(widgets, placement: .belowEditor).map(\.key) == [
            "subagent-custom",
        ])
    }

    @Test("runtime working row follows phase, visibility, message, and retry policy")
    func runtimeWorkingRowPolicy() {
        struct PolicyCase {
            let name: String
            let phase: SessionPhase
            let visible: Bool
            let message: String?
            let retry: RetryState?
            let expectedMessage: String?
            let expectedRetryMessage: String?
        }

        let retryWithMaximum = RetryState(
            source: .agent,
            attempt: 2,
            maxAttempts: 4,
            delayMs: 500,
            errorMessage: "transient"
        )
        let retryWithoutMaximum = RetryState(
            source: .compaction,
            attempt: 3,
            maxAttempts: nil,
            delayMs: nil,
            errorMessage: nil
        )
        let cases = [
            PolicyCase(
                name: "running visible default message without retry",
                phase: .running, visible: true, message: nil, retry: nil,
                expectedMessage: "Tron is working", expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "running invisible custom message with retry maximum",
                phase: .running, visible: false, message: "Reading files", retry: retryWithMaximum,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "compacting visible custom message with retry without maximum",
                phase: .compacting, visible: true, message: "Trimming history", retry: retryWithoutMaximum,
                expectedMessage: "Trimming history", expectedRetryMessage: "Attempt 3"
            ),
            PolicyCase(
                name: "compacting invisible default message without retry",
                phase: .compacting, visible: false, message: nil, retry: nil,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "retrying visible default message with retry maximum",
                phase: .retrying, visible: true, message: nil, retry: retryWithMaximum,
                expectedMessage: "Retrying provider", expectedRetryMessage: "Attempt 2 of 4"
            ),
            PolicyCase(
                name: "retrying invisible custom message without retry",
                phase: .retrying, visible: false, message: "Trying again", retry: nil,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "idle visible default message without retry",
                phase: .idle, visible: true, message: nil, retry: nil,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "idle invisible custom message with retry without maximum",
                phase: .idle, visible: false, message: "Ignored", retry: retryWithoutMaximum,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "interrupted visible custom message with retry maximum",
                phase: .interrupted, visible: true, message: "Ignored", retry: retryWithMaximum,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "interrupted invisible default message without retry",
                phase: .interrupted, visible: false, message: nil, retry: nil,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
        ]

        for policyCase in cases {
            let presentation = ChatRuntimeWorkingPresentation(
                phase: policyCase.phase,
                working: .init(message: policyCase.message, visible: policyCase.visible),
                retry: policyCase.retry
            )
            #expect(
                (presentation != nil) == (policyCase.expectedMessage != nil),
                "unexpected visibility for \(policyCase.name)"
            )
            #expect(
                presentation?.message == policyCase.expectedMessage,
                "unexpected message for \(policyCase.name)"
            )
            #expect(
                presentation?.retryMessage == policyCase.expectedRetryMessage,
                "unexpected retry message for \(policyCase.name)"
            )
        }
    }

    @Test("zero and partial geometry never masquerade as bottom readiness")
    func chatGeometryValidity() {
        #expect(!ChatTranscriptGeometry.zero.isValid)
        #expect(!ChatTranscriptGeometry.zero.isAtExactBottom)
        let partial = ChatTranscriptGeometry(offsetY: 0, contentHeight: 100, containerHeight: 0)
        #expect(!partial.isValid)
        #expect(!partial.isAtBottom)
        let ready = ChatTranscriptGeometry(offsetY: 400, contentHeight: 800, containerHeight: 400)
        #expect(ready.isValid)
        #expect(ready.isAtExactBottom)

        let insetBottom = ChatTranscriptGeometry(
            offsetY: 472, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        let insetAway = ChatTranscriptGeometry(
            offsetY: 372, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        #expect(insetBottom.isAtExactBottom)
        #expect(insetBottom.isAtCatchUpBoundary)
        #expect(insetAway.distanceFromBottom == 100)
        #expect(!insetAway.isAtBottom)
        let roundedTail = ChatTranscriptGeometry(
            offsetY: 460, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        #expect(!roundedTail.isAtExactBottom)
        #expect(roundedTail.isAtCatchUpBoundary)
    }

    @Test("chat toolbar title remains bounded during interactive navigation")
    func toolbarTitleWidth() {
        #expect(ChatToolbarTitleLayout.width(containerWidth: 0) == 80)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 402) == 250)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 440) == 288)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 1_024) == 360)
    }

    @Test("attachment menu availability is session scoped and independent of draft text")
    func attachmentAvailability() {
        #expect(!ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: false, phase: .idle, isSending: false
        ))
        #expect(!ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: nil, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .running, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .idle, isSending: true
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .idle, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .interrupted, isSending: false
        ))

        let running = ChatAttachmentMenuState(
            sessionID: "session", phase: .running,
            isTranscriptReady: true, isSending: false
        )
        let compacting = ChatAttachmentMenuState(
            sessionID: "session", phase: .compacting,
            isTranscriptReady: true, isSending: false
        )
        let idle = ChatAttachmentMenuState(
            sessionID: "session", phase: .idle,
            isTranscriptReady: true, isSending: false
        )
        let anotherIdle = ChatAttachmentMenuState(
            sessionID: "another-session", phase: .idle,
            isTranscriptReady: true, isSending: false
        )
        #expect(running.actionsEnabled)
        #expect(idle.actionsEnabled)
        #expect(running.identity == compacting.identity)
        #expect(running.identity == idle.identity)
        #expect(idle.identity != anotherIdle.identity)
    }

    @Test("authoritative sync reveals immediately without geometry callbacks")
    func chatOpenPresentationState() {
        var state = ChatOpenPresentationState(sessionID: "session-a")
        let epoch = state.begin()
        let wrongSession = state.installAuthoritativeBaseline(sessionID: "session-b", epoch: epoch)
        let staleEpoch = state.installAuthoritativeBaseline(sessionID: "session-a", epoch: epoch - 1)
        #expect(!wrongSession)
        #expect(!staleEpoch)
        #expect(state.phase == .opening)

        let installed = state.installAuthoritativeBaseline(sessionID: "session-a", epoch: epoch)
        #expect(installed)
        #expect(state.phase == .ready)
    }

    @Test("stale presentation callbacks cannot fail a newer opening epoch")
    func staleChatOpenCallbacks() {
        var state = ChatOpenPresentationState(sessionID: "session-a")
        let staleEpoch = state.begin()
        let currentEpoch = state.begin()
        let stale = state.fail(sessionID: "session-a", epoch: staleEpoch, message: "stale")
        let wrongSession = state.fail(sessionID: "session-b", epoch: currentEpoch, message: "wrong session")
        #expect(!stale)
        #expect(!wrongSession)
        #expect(state.phase == .opening)
        let failed = state.fail(sessionID: "session-a", epoch: currentEpoch, message: "offline")
        #expect(failed)
        #expect(state.phase == .failed("offline"))
    }

    @Test("earlier page responses require the exact mounted generation and cursor")
    func earlierPageRequestIdentity() {
        let request = ChatTranscriptPageRequest(
            sessionID: "session-a",
            presentationGeneration: 7,
            runtimeGeneration: "runtime-a",
            before: 40,
            expectedTotal: 48,
            expectedNextEntryID: "entry-40"
        )
        #expect(request.canInstall(
            sessionID: "session-a", presentationGeneration: 7,
            runtimeGeneration: "runtime-a", transcriptStart: 40,
            transcriptTotal: 48, firstTranscriptID: "entry-40"
        ))
        #expect(!request.canInstall(
            sessionID: "session-a", presentationGeneration: 8,
            runtimeGeneration: "runtime-a", transcriptStart: 40,
            transcriptTotal: 48, firstTranscriptID: "entry-40"
        ))
        #expect(!request.canInstall(
            sessionID: "session-a", presentationGeneration: 7,
            runtimeGeneration: "runtime-a", transcriptStart: 20,
            transcriptTotal: 48, firstTranscriptID: "entry-20"
        ))
    }

    @Test("bootstrap configuration stays in Manage Session")
    func hidesBootstrapConfiguration() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"model","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}},
          {"id":"thinking","parentId":"model","timestamp":"2026-01-01T00:00:01Z","kind":"thinkingChange","level":"high"},
          {"id":"user","parentId":"thinking","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"hello"}]}
        ]
        """)

        #expect(ChatTranscriptPresentation.items(in: snapshot).map(\.id) == ["user"])
    }

    @Test("configuration changes after conversation begins remain notifications")
    func retainsLaterChanges() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"hello"}]},
          {"id":"model","parentId":"user","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}},
          {"id":"thinking","parentId":"model","timestamp":"2026-01-01T00:00:02Z","kind":"thinkingChange","level":"high"}
        ]
        """)

        #expect(ChatTranscriptPresentation.items(in: snapshot).map(\.id) == ["user", "model", "thinking"])
    }

    @Test("initial hydration and session changes do not manufacture unread responses")
    func unreadBaselinePolicy() throws {
        let first = ChatResponseState(snapshot: try fixture(transcript: "[]"))
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: nil,
            current: first,
            userScrolledAway: true
        ))

        var switchedSnapshot = try fixture(transcript: "[]")
        switchedSnapshot.sessionId = "another-session"
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: first,
            current: ChatResponseState(snapshot: switchedSnapshot),
            userScrolledAway: true
        ))
    }

    @Test("new response marks unread only while scrolled away")
    func unreadResponsePolicy() throws {
        let previous = ChatResponseState(snapshot: try fixture(transcript: "[]"))
        let updated = ChatResponseState(snapshot: try fixture(transcript: """
        [{"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"assistant:0","type":"text","text":"hello"}]}]
        """))
        #expect(ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: previous,
            current: updated,
            userScrolledAway: true
        ))
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: previous,
            current: updated,
            userScrolledAway: false
        ))
    }

    @Test("tool run identity follows authoritative order rather than opaque ID sorting")
    func toolRunIdentityUsesAuthoritativeOrder() {
        let ordered = ChatToolRunPresentation(tools: [
            toolPresentation("opaque-z-first"),
            toolPresentation("opaque-a-second"),
        ])
        #expect(ordered.id == "tool-run-opaque-z-first")
    }

    @Test("compaction token counts use compact K shorthand")
    func compactCompactionTokenCounts() {
        #expect(ChatTokenCountPresentation.beforeCompaction(0) == "0 tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(1) == "1 token before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(999) == "999 tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(1_000) == "1K tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(12_300) == "12.3K tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(322_486) == "322K tokens before compaction")
    }

    @Test("notification policy separates flat status from detail-bearing summaries")
    func notificationMaterialPolicy() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"compact","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"Condensed context","tokensBefore":1200},
          {"id":"model","parentId":"compact","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}}
        ]
        """)
        let compact = try #require(ChatNotificationPresentation.canonical(snapshot.transcript[0], globalOrdinal: 8))
        let model = try #require(ChatNotificationPresentation.canonical(snapshot.transcript[1], globalOrdinal: 9))

        #expect(compact.id == "notification-compaction-slot-8")
        #expect(compact.material == .glass)
        #expect(compact.hasDetailSheet)
        #expect(compact.tone == .accent)
        #expect(model.material == .flat)
        #expect(!model.hasDetailSheet)
        #expect(model.detail == "openai-codex / gpt-5.6-sol")
    }

    @Test("whitespace-only summaries stay flat and noninteractive")
    func whitespaceSummaryIsFlat() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"blank","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"  \\n  ","tokensBefore":1200}
        ]
        """)
        let notification = try #require(
            ChatNotificationPresentation.canonical(snapshot.transcript[0], globalOrdinal: 0)
        )
        #expect(notification.body == nil)
        #expect(notification.material == .flat)
        #expect(!notification.hasDetailSheet)
    }

    @Test("pending compaction shares identity only under exact tail bounds")
    func pendingCompactionContinuity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .compacting
        snapshot.extensionUI.working = .init(message: nil, visible: true)
        snapshot.transcriptStart = 7
        snapshot.transcriptTotal = 7
        let exact = try #require(ChatNotificationPresentation.runtime(in: snapshot).first)
        #expect(exact.id == "notification-compaction-slot-7")
        #expect(exact.title == "Compacting context")
        #expect(exact.material == .flat)

        snapshot.transcriptTotal = 8
        let malformed = try #require(ChatNotificationPresentation.runtime(in: snapshot).first)
        #expect(malformed.id == "runtime-working")
        #expect(malformed.id != exact.id)
    }

    @Test("canonical compaction ordinals survive bounded tails and prepends")
    func canonicalCompactionOrdinals() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"compact-a","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"A","tokensBefore":100},
          {"id":"compact-b","parentId":"compact-a","timestamp":"2026-01-01T00:00:01Z","kind":"compaction","summary":"B","tokensBefore":200}
        ]
        """)
        snapshot.transcriptStart = 5
        snapshot.transcriptTotal = 7
        let notifications = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> ChatNotificationPresentation? in
            guard case .notification(let notification) = item else { return nil }
            return notification
        }
        #expect(notifications.map(\.id) == [
            "notification-compaction-slot-5", "notification-compaction-slot-6",
        ])

        snapshot.transcriptStart = 3
        snapshot.transcript.insert(contentsOf: try fixture(transcript: """
        [
          {"id":"older-a","parentId":null,"timestamp":"2025-12-31T23:59:58Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"older"}},
          {"id":"older-b","parentId":"older-a","timestamp":"2025-12-31T23:59:59Z","kind":"thinkingChange","level":"low"}
        ]
        """).transcript, at: 0)
        let prepended = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> ChatNotificationPresentation? in
            guard case .notification(let notification) = item,
                  notification.id.hasPrefix("notification-compaction-slot") else { return nil }
            return notification
        }
        #expect(prepended.map(\.id) == notifications.map(\.id))

        snapshot.transcriptTotal = 99
        let malformed = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> String? in
            guard case .notification(let notification) = item,
                  notification.semanticID?.hasPrefix("compact-") == true else { return nil }
            return notification.id
        }
        #expect(malformed == [
            "notification-compaction-compact-a", "notification-compaction-compact-b",
        ])
    }

    @Test("duplicate canonical IDs fail safe without ordinal construction trap")
    func duplicateCompactionIDsFailSafe() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"A","tokensBefore":100},
          {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"compaction","summary":"B","tokensBefore":200}
        ]
        """)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 2
        let ids = ChatTranscriptPresentation.timeline(in: snapshot).items.map(\.id)
        #expect(ids == [
            "notification-compaction-duplicate", "notification-compaction-duplicate",
        ])
    }

    @Test("prompt images and files share one attachment strip above text")
    func promptAttachmentStrip() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[
            {"id":"user:0","type":"text","text":"What about these?"},
            {"id":"user:1","type":"image","mimeType":"image/jpeg","blobId":"photo"},
            {"id":"user:2","type":"text","text":"notes.pdf","attachment":{"name":"notes.pdf","mimeType":"application/pdf","size":2048}}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let attachments = ChatTranscriptPresentation.attachmentParts(in: item)
        #expect(attachments.map(\.type) == [.image, .text])
        #expect(attachments.last?.attachment?.name == "notes.pdf")
        #expect(attachments.last?.attachment?.size == 2048)
    }

    @Test("consecutive thinking lines become one complete inline run")
    func groupsConsecutiveThinkingLines() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"  Inspecting the transcript  \\nChecking spacing..."},
            {"id":"thinking-2","type":"thinking","text":"Confirming   the grouped lines…\\n..."},
            {"id":"answer","type":"text","text":"Done"}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let parts = ChatTranscriptPresentation.messageParts(in: item)

        #expect(parts.count == 2)
        guard case .thinking(let run) = parts[0] else {
            Issue.record("Expected one thinking run")
            return
        }
        #expect(run.id == "thinking-1")
        #expect(run.segments.map(\.id) == [
            "thinking-1:line:0",
            "thinking-1:line:1",
            "thinking-2:line:0",
            "thinking-2:line:1",
        ])
        #expect(run.segments.map(\.text) == [
            "Inspecting the transcript…",
            "Checking spacing…",
            "Confirming the grouped lines…",
            "…",
        ])
        guard case .content(let answer) = parts[1] else {
            Issue.record("Expected answer after thinking")
            return
        }
        #expect(answer.id == "answer")
    }

    @Test("content boundaries keep thinking runs separate and stable")
    func thinkingRunBoundaries() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"thinking-empty","type":"thinking","text":"  \\n  "},
            {"id":"thinking-2","type":"thinking","text":"Second"}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let parts = ChatTranscriptPresentation.messageParts(in: item)

        #expect(parts.map(\.id) == ["thinking-thinking-1", "content-call", "thinking-thinking-2"])
        guard case .thinking(let trailingRun) = parts[2] else {
            Issue.record("Expected trailing thinking run")
            return
        }
        #expect(trailingRun.segments.map(\.id) == ["thinking-2:line:0"])
        #expect(trailingRun.segments.map(\.text) == ["Second…"])
    }

    @Test("timeline preserves thinking around an intervening tool")
    func preservesThinkingToolOrder() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"thinking-2","type":"thinking","text":"Second"}
          ]}
        ]
        """)
        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)

        #expect(timeline.ids == [
            "assistant",
            "tool-run-call-1",
            "assistant-slice-thinking-thinking-2",
        ])
        guard case .message(let first) = timeline.items[0],
              case .thinking(let firstRun) = first.parts.first,
              case .toolRun(let toolRun) = timeline.items[1],
              case .message(let last) = timeline.items[2],
              case .thinking(let lastRun) = last.parts.first else {
            Issue.record("Expected thinking slices around the tool run")
            return
        }
        #expect(firstRun.segments.map(\.text) == ["First…"])
        #expect(toolRun.tools.first?.content == "")
        #expect(toolRun.tools.first?.request == .object([:]))
        #expect(toolRun.tools.first?.fallbackContent == .object([:]))
        #expect(lastRun.segments.map(\.text) == ["Second…"])
    }

    @Test("thinking barriers preserve exact order across multiple consolidated tool runs")
    func thinkingBarriersPreserveToolOrder() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"call-2","type":"toolCall","toolCallId":"call-2","name":"read","arguments":{}},
            {"id":"thinking-2","type":"thinking","text":"Between"},
            {"id":"call-3","type":"toolCall","toolCallId":"call-3","name":"bash","arguments":{}},
            {"id":"thinking-3","type":"thinking","text":"Last"}
          ]}
        ]
        """)
        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)

        #expect(timeline.ids == [
            "assistant",
            "tool-run-call-1",
            "assistant-slice-thinking-thinking-2",
            "tool-run-call-3",
            "assistant-slice-thinking-thinking-3",
        ])
        guard case .toolRun(let firstRun) = timeline.items[1],
              case .message(let between) = timeline.items[2],
              case .thinking(let betweenThinking) = between.parts.first,
              case .toolRun(let secondRun) = timeline.items[3] else {
            Issue.record("Expected thinking to split canonical tool runs")
            return
        }
        #expect(firstRun.tools.map(\.id) == ["call-1", "call-2"])
        #expect(betweenThinking.segments.map(\.text) == ["Between…"])
        #expect(secondRun.tools.map(\.id) == ["call-3"])
    }

    @Test("consecutive tool calls collapse into one presentation run")
    func groupsConsecutiveToolCalls() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{"path":"one"}}]},
          {"id":"result-1","parentId":"assistant-1","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text-1","type":"text","text":"one"}],"toolCallId":"call-1","toolName":"read","isError":false},
          {"id":"assistant-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"}}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)

        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)
        let rendered = timeline.items
        #expect(rendered.count == 1)
        guard case .toolRun(let run) = rendered.first else {
            Issue.record("Expected one grouped tool run")
            return
        }
        #expect(run.tools.map(\.title) == ["read", "bash"])
        #expect(run.tools[0].request == .object(["path": .string("one")]))
        #expect(run.tools[0].response == nil)
        #expect(run.tools[1].request == .object(["command": .string("pwd")]))
        #expect(run.title == "Used 2 tools")
        #expect(timeline.preferredSemanticIDByRenderedID[run.id] == "call-2")
        #expect(timeline.renderedIDBySemanticID["call-1"] == run.id)
        #expect(timeline.renderedIDBySemanticID["call-2"] == run.id)
    }

    @Test("semantic tool anchor survives page-boundary regrouping when the outer row changes")
    func semanticAnchorSurvivesPageBoundaryRegrouping() throws {
        let current = try fixture(transcript: """
        [
          {"id":"assistant-2","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"}}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)
        let before = ChatTranscriptPresentation.timeline(in: current)
        #expect(before.ids == ["tool-run-call-2"])
        #expect(before.preferredSemanticIDByRenderedID["tool-run-call-2"] == "call-2")

        let prepended = try fixture(transcript: """
        [
          {"id":"assistant-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{"path":"one"}}]},
          {"id":"result-1","parentId":"assistant-1","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text-1","type":"text","text":"one"}],"toolCallId":"call-1","toolName":"read","isError":false},
          {"id":"assistant-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"}}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)
        let after = ChatTranscriptPresentation.timeline(in: prepended)
        #expect(after.ids == ["tool-run-call-1"])
        #expect(after.renderedIDBySemanticID["call-2"] == "tool-run-call-1")
    }

    @Test("parallel live tools keep one stable canonical row through settlement")
    func liveToolsKeepStableTimelineIdentity() throws {
        let callOne = "call-1"
        let callTwo = "call-2"
        let callThree = "call-3"
        var snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"test tools"}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
          {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
          {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
        ]}
        """)
        snapshot.toolExecutions = [
            tool(callOne, "bash", startedAt: "2026-01-01T00:00:01Z"),
            tool(callTwo, "read", startedAt: "2026-01-01T00:00:01Z"),
            tool(callThree, "subagent", startedAt: "2026-01-01T00:00:01Z"),
        ]

        let live = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(live.ids == ["user", "streaming", "tool-run-call-1"])
        guard case .toolRun(let liveRun) = live.items.last else {
            Issue.record("Expected a live tool run")
            return
        }
        #expect(liveRun.tools.map(\.id) == [callOne, callTwo, callThree])
        #expect(liveRun.title == "Using 3 tools")

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}}
        ]}
        """)
        snapshot.toolExecutions = [snapshot.toolExecutions[0]]
        let partial = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(partial.ids.last == "tool-run-call-1")

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
          {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
          {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
        ]}
        """)
        snapshot.toolExecutions = [
            tool(callThree, "subagent", startedAt: "2026-01-01T00:00:01Z", order: 2),
            tool(callOne, "bash", startedAt: "2026-01-01T00:00:01Z", order: 0),
            tool(callTwo, "read", startedAt: "2026-01-01T00:00:01Z", order: 1),
        ]
        let expanded = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(expanded.ids.last == partial.ids.last)
        guard case .toolRun(let expandedRun) = expanded.items.last else {
            Issue.record("Expected expanded live tool run")
            return
        }
        #expect(expandedRun.tools.map(\.id) == [callOne, callTwo, callThree])

        snapshot.transcript = try transcript("""
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"test tools"}]},
          {"id":"assistant-tools","parentId":"user","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
            {"id":"thinking","type":"thinking","text":"Testing tools"},
            {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
            {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
            {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
          ]},
          {"id":"result-1","parentId":"assistant-tools","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r1","type":"text","text":"one"}],"toolCallId":"\(callOne)","toolName":"bash","isError":false},
          {"id":"result-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r2","type":"text","text":"two"}],"toolCallId":"\(callTwo)","toolName":"read","isError":false},
          {"id":"result-3","parentId":"result-2","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r3","type":"text","text":"three"}],"toolCallId":"\(callThree)","toolName":"subagent","isError":false}
        ]
        """)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"All done"}]}
        """)
        snapshot.toolExecutions = snapshot.toolExecutions.map {
            tool($0.toolCallId, $0.toolName, status: .completed, startedAt: $0.startedAt)
        }

        let completing = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(completing.ids == ["user", "assistant-tools", "tool-run-call-1", "streaming"])
        #expect(completing.ids.filter { $0 == "tool-run-call-1" }.count == 1)
        guard case .toolRun(let completedRun) = completing.items[2] else {
            Issue.record("Expected the settled tool run before the response")
            return
        }
        #expect(completedRun.title == "Used 3 tools")

        snapshot.transcript.append(try message("""
        {"id":"assistant-final","parentId":"result-3","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"All done"}]}
        """))
        snapshot.streaming = nil
        snapshot.toolExecutions = []
        let settled = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(settled.ids == ["user", "assistant-tools", "tool-run-call-1", "assistant-final"])
    }

    @Test("isolated text streaming tail is identical to cold whole-timeline projection")
    func isolatedStreamingParity() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"prompt","type":"text","text":"continue"}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [
            tool(
                "completed-live",
                "read",
                status: .completed,
                startedAt: "2026-01-01T00:00:01Z"
            ),
        ]
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":"user","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"thinking","type":"thinking","text":"Preparing"},{"id":"answer","type":"text","text":"Current answer"}]}
        """)

        let cold = ChatTranscriptPresentation.timeline(in: snapshot)
        let streaming = try #require(snapshot.streaming)
        var baseSnapshot = snapshot
        baseSnapshot.streaming = nil
        let base = ChatTranscriptPresentation.timeline(in: baseSnapshot)
        let live = try #require(ChatTranscriptPresentation.isolatedStreamingTimeline(streaming))
        let incremental = base.appendingLive(live)

        #expect(incremental == cold)
        #expect(incremental.items.canonical.count == base.items.count)
        #expect(incremental.items.live.count == 1)
    }

    @Test("explicit empty tool output never falls back to duplicated request content")
    func explicitEmptyToolOutputPreservesDetailParity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [
            tool(
                "empty-output",
                "read",
                status: .completed,
                startedAt: "2026-01-01T00:00:01Z",
                output: ""
            ),
        ]

        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)
        guard case .toolRun(let run) = timeline.items.first,
              let tool = run.tools.first else {
            Issue.record("Expected completed tool row")
            return
        }
        #expect(tool.content == "")
        #expect(tool.fallbackContent == nil)
        #expect(tool.response == .object(["ok": .bool(true)]))
    }

    @Test("live tool order is deterministic when progress events arrive out of order")
    func deterministicLiveToolOrder() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [
            tool("later", "read", startedAt: "2026-01-01T00:00:01Z", order: 2),
            tool("same-b", "bash", startedAt: "2026-01-01T00:00:01Z", order: 1),
            tool("same-a", "find", startedAt: "2026-01-01T00:00:01Z", order: 0),
        ]
        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)
        guard case .toolRun(let run) = timeline.items.first else {
            Issue.record("Expected deterministic live run")
            return
        }
        #expect(run.tools.map(\.id) == ["same-a", "same-b", "later"])
    }

    @Test("live output, monotonic progress, and execution timing stay auditable")
    func liveToolAuditProjection() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"wait","name":"subagent_wait","arguments":{"id":"child"}}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [ToolExecutionState(
            toolCallId: "wait",
            toolName: "subagent_wait",
            order: 0,
            status: .running,
            arguments: .object(["id": .string("child")]),
            partialResult: .object(["content": .array([.object(["type": .string("text"), "text": .string("Waiting 12s · reviewer: read")])])]),
            result: nil,
            output: "Waiting 12s · reviewer: read",
            outputTruncated: true,
            isError: false,
            startedAt: "2026-01-01T00:00:01Z",
            updatedAt: "2026-01-01T00:00:13Z",
            lastProgressAt: "2026-01-01T00:00:13Z",
            progressSequence: 14
        )]

        guard case .toolRun(let run) = ChatTranscriptPresentation.timeline(in: snapshot).items.first else {
            Issue.record("Expected live tool run")
            return
        }
        let tool = try #require(run.tools.first)
        #expect(tool.content == "Waiting 12s · reviewer: read")
        #expect(tool.outputTruncated)
        #expect(tool.progressSequence == 14)
        #expect(tool.elapsedMilliseconds(at: try #require(ToolTiming.date("2026-01-01T00:00:13Z"))) == 12_000)
        #expect(ToolTiming.format(milliseconds: 478_000) == "7m 58s")
    }

    @Test("tool timing parses cached ISO timestamps with and without fractional seconds")
    func toolTimingISOParsing() throws {
        let whole = try #require(ToolTiming.date("2026-01-01T00:00:01Z"))
        let fractional = try #require(ToolTiming.date("2026-01-01T00:00:01.125Z"))
        #expect(Int((fractional.timeIntervalSince(whole) * 1_000).rounded()) == 125)
        #expect(ToolTiming.intervalMilliseconds(
            start: "2026-01-01T00:00:01.125Z",
            end: "2026-01-01T00:00:02Z"
        ) == 875)
        #expect(ToolTiming.date("not-a-timestamp") == nil)
    }

    @Test("canonical history derives timing when exact runtime metadata is unavailable")
    func canonicalTimingFallback() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"read","name":"read","arguments":{}}]},
          {"id":"result","parentId":"assistant","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"text","type":"text","text":"done"}],"toolCallId":"read","toolName":"read","isError":false,"completedAt":"2026-01-01T00:00:03Z"}
        ]
        """)
        guard case .toolRun(let run) = ChatTranscriptPresentation.timeline(in: snapshot).items.first,
              let tool = run.tools.first else {
            Issue.record("Expected canonical tool run")
            return
        }
        #expect(tool.durationMs == 2_000)
        #expect(tool.elapsedMilliseconds() == 2_000)
    }

    @Test("conversation content interrupts tool grouping")
    func conversationBreaksToolRuns() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-tool","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part","type":"toolCall","toolCallId":"call","name":"read","arguments":{}}]},
          {"id":"result","parentId":"assistant-tool","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"done"}],"toolCallId":"call","toolName":"read","isError":false},
          {"id":"assistant-text","parentId":"result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"Finished"}]},
          {"id":"bash","parentId":"assistant-text","timestamp":"2026-01-01T00:00:03Z","kind":"bash","command":"pwd","output":"/workspace","exitCode":0,"cancelled":false,"truncated":false}
        ]
        """)

        let rendered = ChatTranscriptPresentation.timeline(in: snapshot).items
        #expect(rendered.count == 3)
        #expect(rendered.map(\.id) == ["tool-run-call", "assistant-text", "bash"])
    }

    @Test("idle snapshots never present retained foreground tools as running")
    func idleRunningToolIsInterrupted() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"wait","name":"subagent_wait","arguments":{}}]}
        ]
        """)
        snapshot.toolExecutions = [tool("wait", "subagent_wait", startedAt: "2026-01-01T00:00:01Z")]

        guard case .toolRun(let run) = ChatTranscriptPresentation.timeline(in: snapshot).items.first else {
            Issue.record("Expected retained tool run")
            return
        }
        #expect(run.title == "Used 1 tool")
        #expect(!run.isRunning)
        #expect(run.tools.first?.subtitle == "Interrupted")
    }

    @Test("timeline projection closes one aggregate-only performance interval")
    func projectionSignpost() throws {
        let snapshot = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"Hello"}]}]
        """)
        let signposts = RecordingPerformanceSignposts()

        let timeline = ChatTranscriptPresentation.timeline(
            in: snapshot,
            performanceSignposts: signposts
        )

        #expect(timeline.items.count == 1)
        #expect(signposts.events() == [
            .begin(.chatProjection),
            .end(.chatProjection, .success, PerformanceMetrics(itemCount: 1)),
        ])
    }

    private func toolPresentation(_ id: String) -> ChatToolPresentation {
        ChatToolPresentation(
            id: id,
            title: "read",
            subtitle: "Running",
            request: nil,
            response: nil,
            content: "",
            fallbackContent: nil,
            error: false,
            startedAt: nil,
            completedAt: nil,
            durationMs: nil,
            lastProgressAt: nil,
            progressSequence: nil
        )
    }

    private func message(_ value: String) throws -> TranscriptItem {
        try JSONDecoder.gateway.decode(TranscriptItem.self, from: Data(value.utf8))
    }

    private func transcript(_ value: String) throws -> [TranscriptItem] {
        try JSONDecoder.gateway.decode([TranscriptItem].self, from: Data(value.utf8))
    }

    private func tool(
        _ id: String,
        _ name: String,
        status: ToolExecutionState.Status = .running,
        startedAt: String,
        order: Int? = nil,
        output: String? = nil
    ) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: id,
            toolName: name,
            order: order,
            status: status,
            arguments: .object([:]),
            partialResult: nil,
            result: status == .running ? nil : .object(["ok": .bool(true)]),
            output: output,
            isError: status == .failed,
            startedAt: startedAt,
            updatedAt: startedAt,
            lastProgressAt: startedAt,
            completedAt: status == .running ? nil : startedAt,
            durationMs: status == .running ? nil : 0,
            progressSequence: 1
        )
    }

    private func fixture(transcript: String) throws -> SessionSnapshot {
        try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data("""
        {
          "sessionId":"session","runtimeGeneration":"generation","revision":1,"eventSequence":1,"phase":"idle","cwd":"/workspace",
          "model":{"provider":"openai-codex","id":"gpt-5.6-sol"},"thinkingLevel":"high","availableThinkingLevels":["off","high"],
          "stats":{"userMessages":1,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":1,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0},
          "queued":{"steering":[],"followUp":[]},"transcript":\(transcript),"transcriptStart":0,"transcriptTotal":3,
          "toolExecutions":[],"extensionUI":{"statuses":{},"working":{"visible":false},"widgets":[],"editorRevision":0,"editorText":"","pendingInteractions":[]},"diagnostics":[]
        }
        """.utf8))
    }
}
