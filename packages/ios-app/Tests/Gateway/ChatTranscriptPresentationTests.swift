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

        let rendered = ChatTranscriptPresentation.renderItems(in: snapshot)
        #expect(rendered.count == 1)
        guard case .toolRun(let run) = rendered.first else {
            Issue.record("Expected one grouped tool run")
            return
        }
        #expect(run.tools.map(\.title) == ["read", "bash"])
        #expect(run.title == "Used 2 tools")
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

        let rendered = ChatTranscriptPresentation.renderItems(in: snapshot)
        #expect(rendered.count == 3)
        #expect(rendered.map(\.id) == ["tool-run-call", "assistant-text", "tool-run-bash"])
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
