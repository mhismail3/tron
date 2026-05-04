import Foundation
import Testing
@testable import TronMobile

@Suite("Codex App state reducer")
@MainActor
struct CodexAppReducerTests {
    private func threadPayload(messageCount: Int, itemCount: Int = 0) -> [String: Any] {
        var turns: [[String: Any]] = (0..<messageCount).map { index in
            [
                "id": "turn-message-\(index)",
                "items": [
                    [
                        "id": "user-\(index)",
                        "type": "userMessage",
                        "content": [
                            ["type": "text", "text": "message \(index)"]
                        ]
                    ]
                ]
            ]
        }
        turns.append(contentsOf: (0..<itemCount).map { index in
            [
                "id": "turn-item-\(index)",
                "items": [
                    [
                        "id": "cmd-\(index)",
                        "type": "commandExecution",
                        "command": "echo \(index)",
                        "cwd": "/repo",
                        "status": "completed",
                        "aggregatedOutput": "output \(index)"
                    ]
                ]
            ]
        })

        return [
            "id": "thr-long",
            "preview": "Long thread",
            "cwd": "/repo",
            "modelProvider": "openai",
            "createdAt": "2026-05-03T00:00:00Z",
            "turns": turns
        ]
    }

    private func decodeThread(messageCount: Int, itemCount: Int = 0) throws -> CodexThread {
        let payload = threadPayload(messageCount: messageCount, itemCount: itemCount)
        return try decodeThread(payload: payload)
    }

    private func decodeThread(payload: [String: Any]) throws -> CodexThread {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(CodexThread.self, from: data)
    }

    @Test("thread list sorts newest first and preserves selected thread")
    func threadListSorting() {
        var state = CodexAppState()
        state.selectedThreadId = "old"
        let old = CodexThreadSummary(id: "old", title: "Old", cwd: "/old", model: "gpt-5.4", createdAt: "2026-05-01T00:00:00Z", status: .idle)
        let new = CodexThreadSummary(id: "new", title: "New", cwd: "/new", model: "gpt-5.4", createdAt: "2026-05-02T00:00:00Z", status: .idle)

        CodexAppReducer.apply(.threadsLoaded([old, new]), to: &state)

        #expect(state.threads.map(\.id) == ["new", "old"])
        #expect(state.selectedThreadId == "old")
    }

    @Test("thread list does not auto-open a thread on dashboard load")
    func threadListDoesNotAutoSelect() {
        var state = CodexAppState()
        let thread = CodexThreadSummary(id: "new", title: "New", cwd: "/repo", model: "gpt-5.4", createdAt: "2026-05-02T00:00:00Z", status: .idle)

        CodexAppReducer.apply(.threadsLoaded([thread]), to: &state)

        #expect(state.threads.map(\.id) == ["new"])
        #expect(state.selectedThreadId == nil)
        #expect(!state.isDraftingNewThread)
    }

    @Test("resumed long thread renders latest history window first")
    func resumedLongThreadRendersLatestHistoryWindowFirst() throws {
        var state = CodexAppState()
        let count = CodexAppHistoryWindow.initialMessageLimit + 5
        let thread = try decodeThread(messageCount: count)

        CodexAppReducer.apply(.threadResumed(thread), to: &state)

        #expect(state.entries.count == CodexAppHistoryWindow.initialEntryLimit)
        #expect(state.earlierEntries.count == 5)
        #expect(state.messages.count == CodexAppHistoryWindow.initialMessageLimit)
        #expect(state.earlierMessages.count == 5)
        #expect(state.messages.first?.content.textContent == "message 5")
        #expect(state.messages.last?.content.textContent == "message \(count - 1)")
        #expect(state.items.isEmpty)
        #expect(state.earlierItems.isEmpty)
        #expect(state.hasEarlierEntries)
    }

    @Test("resumed mixed thread preserves chronological transcript")
    func resumedMixedThreadPreservesChronologicalTranscript() throws {
        var state = CodexAppState()
        let thread = try decodeThread(payload: [
            "id": "thr-mixed",
            "preview": "Mixed thread",
            "cwd": "/repo",
            "modelProvider": "openai",
            "createdAt": "2026-05-03T00:00:00Z",
            "turns": [
                [
                    "id": "turn-1",
                    "items": [
                        [
                            "id": "user-1",
                            "type": "userMessage",
                            "content": [["type": "text", "text": "before command"]]
                        ],
                        [
                            "id": "cmd-1",
                            "type": "commandExecution",
                            "command": "git status",
                            "cwd": "/repo",
                            "status": "completed",
                            "aggregatedOutput": "clean"
                        ],
                        [
                            "id": "assistant-1",
                            "type": "agentMessage",
                            "text": "after command"
                        ],
                        [
                            "id": "file-1",
                            "type": "fileChange",
                            "status": "completed",
                            "changes": [
                                ["path": "/repo/App.swift", "kind": "modified", "diff": "@@ -1 +1 @@"]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        CodexAppReducer.apply(.threadResumed(thread), to: &state)

        #expect(state.entries.count == 4)
        #expect(state.messages.map(\.content.textContent) == ["before command", "after command"])
        #expect(state.items.count == 2)
        #expect(state.items.contains(.command(id: "cmd-1", command: "git status", cwd: "/repo", status: "completed", output: "clean")))
        #expect(state.items.contains(.fileChange(id: "file-1", status: "completed", summary: "/repo/App.swift modified\n@@ -1 +1 @@")))
        #expect(state.entries.map(\.id) == [
            "message-\(state.messages[0].id.uuidString)",
            "item-cmd-1",
            "message-\(state.messages[1].id.uuidString)",
            "item-file-1"
        ])
    }

    @Test("agent deltas create and update a streaming assistant message")
    func agentDeltasStream() {
        var state = CodexAppState()
        state.selectedThreadId = "thr"

        CodexAppReducer.apply(.turnStarted(threadId: "thr", turnId: "turn"), to: &state)
        CodexAppReducer.apply(.agentMessageDelta(threadId: "thr", turnId: "turn", itemId: "item", delta: "Hel"), to: &state)
        CodexAppReducer.apply(.agentMessageDelta(threadId: "thr", turnId: "turn", itemId: "item", delta: "lo"), to: &state)

        #expect(state.messages.count == 1)
        #expect(state.messages[0].content.textContent == "Hello")
        #expect(state.messages[0].isStreaming)
    }

    @Test("completed agent item finalizes streaming message")
    func completedAgentFinalizes() {
        var state = CodexAppState()
        CodexAppReducer.apply(.agentMessageDelta(threadId: "thr", turnId: "turn", itemId: "item", delta: "Draft"), to: &state)

        CodexAppReducer.apply(.itemCompleted(CodexAppItem.agentMessage(id: "item", text: "Final")), to: &state)

        #expect(state.messages[0].content.textContent == "Final")
        #expect(!state.messages[0].isStreaming)
    }

    @Test("item lifecycle notifications render command and file items")
    func itemLifecycleNotificationsRenderItems() {
        var state = CodexAppState()
        let commandStarted = CodexJSONRPCNotification(
            method: "item/started",
            params: [
                "item": AnyCodable([
                    "type": "commandExecution",
                    "id": "cmd",
                    "command": "swift test",
                    "cwd": "/repo",
                    "status": "inProgress"
                ])
            ]
        )
        let commandCompleted = CodexJSONRPCNotification(
            method: "item/completed",
            params: [
                "item": AnyCodable([
                    "type": "commandExecution",
                    "id": "cmd",
                    "command": "swift test",
                    "cwd": "/repo",
                    "status": "completed",
                    "aggregatedOutput": "ok"
                ])
            ]
        )
        let fileCompleted = CodexJSONRPCNotification(
            method: "item/completed",
            params: [
                "item": AnyCodable([
                    "type": "fileChange",
                    "id": "file",
                    "status": "completed",
                    "changes": [
                        ["path": "/repo/App.swift", "kind": "modified", "diff": "@@ -1 +1 @@"]
                    ]
                ])
            ]
        )

        CodexAppReducer.apply(CodexAppReducer.event(from: commandStarted), to: &state)
        CodexAppReducer.apply(CodexAppReducer.event(from: commandCompleted), to: &state)
        CodexAppReducer.apply(CodexAppReducer.event(from: fileCompleted), to: &state)

        #expect(state.items.count == 2)
        #expect(state.items.contains(.command(id: "cmd", command: "swift test", cwd: "/repo", status: "completed", output: "ok")))
        #expect(state.items.contains(.fileChange(id: "file", status: "completed", summary: "/repo/App.swift modified\n@@ -1 +1 @@")))
    }

    @Test("plan and reasoning deltas stream into stable item rows")
    func planAndReasoningDeltasStreamIntoItems() {
        var state = CodexAppState()

        CodexAppReducer.apply(CodexAppReducer.event(from: CodexJSONRPCNotification(
            method: "item/plan/delta",
            params: ["itemId": AnyCodable("plan-1"), "delta": AnyCodable("Step 1")]
        )), to: &state)
        CodexAppReducer.apply(CodexAppReducer.event(from: CodexJSONRPCNotification(
            method: "item/reasoning/summaryTextDelta",
            params: ["itemId": AnyCodable("reason-1"), "delta": AnyCodable("Thinking")]
        )), to: &state)

        #expect(state.latestPlan == "Step 1")
        #expect(state.items.contains(.plan(id: "plan-1", text: "Step 1")))
        #expect(state.items.contains(.reasoning(id: "reason-1", text: "Thinking", isStreaming: true)))
    }

    @Test("approval requests are stored and cleared by decision")
    func approvals() {
        var state = CodexAppState()
        let request = CodexApprovalRequest(
            requestId: .string("req"),
            kind: .command,
            threadId: "thr",
            turnId: "turn",
            itemId: "item",
            reason: "needs shell"
        )

        CodexAppReducer.apply(.approvalRequested(request), to: &state)
        #expect(state.pendingApprovals.count == 1)

        CodexAppReducer.apply(.approvalResolved(requestId: .string("req")), to: &state)
        #expect(state.pendingApprovals.isEmpty)
    }

    @Test("serverRequest resolved notification clears stale approvals")
    func serverRequestResolvedClearsApproval() {
        var state = CodexAppState()
        state.pendingApprovals = [
            CodexApprovalRequest(
                requestId: .string("approval-1"),
                kind: .command,
                threadId: "thr",
                turnId: "turn",
                itemId: "cmd",
                reason: nil
            )
        ]

        let event = CodexAppReducer.event(from: CodexJSONRPCNotification(
            method: "serverRequest/resolved",
            params: ["requestId": AnyCodable("approval-1")]
        ))
        CodexAppReducer.apply(event, to: &state)

        #expect(state.pendingApprovals.isEmpty)
    }

    @Test("current nested error notification records message")
    func nestedErrorNotificationRecordsMessage() {
        var state = CodexAppState()
        let event = CodexAppReducer.event(from: CodexJSONRPCNotification(
            method: "error",
            params: ["error": AnyCodable(["message": "Usage limit reached"])]
        ))

        CodexAppReducer.apply(event, to: &state)

        #expect(state.errorMessage == "Usage limit reached")
        #expect(state.messages.last?.content.textContent == "Usage limit reached")
    }

    @Test("unknown notifications add no visible messages")
    func unknownNotificationsAreIgnored() {
        var state = CodexAppState()

        CodexAppReducer.apply(.unknownNotification(method: "future/event"), to: &state)

        #expect(state.messages.isEmpty)
    }
}
