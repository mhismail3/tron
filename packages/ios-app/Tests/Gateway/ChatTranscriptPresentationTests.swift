import Foundation
import Testing
@testable import TronMobile

@Suite("Chat transcript presentation")
struct ChatTranscriptPresentationTests {
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
