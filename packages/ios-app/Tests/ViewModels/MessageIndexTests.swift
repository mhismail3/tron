import Testing
import Foundation
@testable import TronMobile

@Suite("MessageIndex")
@MainActor
struct MessageIndexTests {

    // MARK: - Helpers

    private func makeMessage(id: UUID = UUID(), text: String = "hello") -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: .text(text))
    }

    private func makeToolMessage(id: UUID = UUID(), toolCallId: String) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            content: .toolUse(ToolUseData(
                toolName: "Bash",
                toolCallId: toolCallId,
                arguments: "{}",
                status: .running
            ))
        )
    }

    // MARK: - indexById

    @Test("indexById returns correct index after append")
    func indexById_afterAppend() {
        let index = MessageIndex()
        let m1 = makeMessage()
        let m2 = makeMessage()
        let m3 = makeMessage()

        index.didAppend(m1, at: 0)
        index.didAppend(m2, at: 1)
        index.didAppend(m3, at: 2)

        #expect(index.index(for: m1.id) == 0)
        #expect(index.index(for: m2.id) == 1)
        #expect(index.index(for: m3.id) == 2)
    }

    @Test("indexById returns correct index after remove at middle")
    func indexById_afterRemoveAtMiddle() {
        let index = MessageIndex()
        let m1 = makeMessage()
        let m2 = makeMessage()
        let m3 = makeMessage()

        index.didAppend(m1, at: 0)
        index.didAppend(m2, at: 1)
        index.didAppend(m3, at: 2)

        // Remove m2 (index 1)
        index.didRemove(m2, at: 1, newTotalCount: 2)

        #expect(index.index(for: m1.id) == 0)
        #expect(index.index(for: m2.id) == nil)
        #expect(index.index(for: m3.id) == 1) // shifted left
    }

    @Test("indexById returns nil for unknown id")
    func indexById_unknownId() {
        let index = MessageIndex()
        #expect(index.index(for: UUID()) == nil)
    }

    @Test("indexById correct after insert at index")
    func indexById_afterInsert() {
        let index = MessageIndex()
        let m1 = makeMessage()
        let m3 = makeMessage()

        index.didAppend(m1, at: 0)
        index.didAppend(m3, at: 1)

        // Insert m2 at position 1
        let m2 = makeMessage()
        index.didInsert(m2, at: 1, totalCount: 3)

        #expect(index.index(for: m1.id) == 0)
        #expect(index.index(for: m2.id) == 1)
        #expect(index.index(for: m3.id) == 2) // shifted right
    }

    // MARK: - toolCallId index

    @Test("toolCallId index tracks tool use messages")
    func toolCallIdIndex_tracksToolUse() {
        let index = MessageIndex()
        let tool = makeToolMessage(toolCallId: "toolu_abc")

        index.didAppend(tool, at: 0)

        #expect(index.index(forToolCallId: "toolu_abc") == 0)
    }

    @Test("toolCallId index removed when message removed")
    func toolCallIdIndex_removedOnRemove() {
        let index = MessageIndex()
        let tool = makeToolMessage(toolCallId: "toolu_abc")

        index.didAppend(tool, at: 0)
        index.didRemove(tool, at: 0, newTotalCount: 0)

        #expect(index.index(forToolCallId: "toolu_abc") == nil)
    }

    // MARK: - Edge cases

    @Test("handles empty messages")
    func handlesEmpty() {
        let index = MessageIndex()
        index.rebuild(from: [])

        #expect(index.index(for: UUID()) == nil)
        #expect(index.index(forToolCallId: "anything") == nil)
    }

    @Test("handles duplicate ids — last one wins")
    func handlesDuplicateIds() {
        let index = MessageIndex()
        let sharedId = UUID()
        let m1 = makeMessage(id: sharedId, text: "first")
        let m2 = makeMessage(id: sharedId, text: "second")

        // Rebuild simulates bulk load where last occurrence wins
        index.rebuild(from: [m1, m2])

        #expect(index.index(for: sharedId) == 1)
    }

    @Test("clearMessages clears index")
    func clearMessages_clearsIndex() {
        let index = MessageIndex()
        let m1 = makeMessage()
        let tool = makeToolMessage(toolCallId: "toolu_xyz")

        index.didAppend(m1, at: 0)
        index.didAppend(tool, at: 1)

        index.clear()

        #expect(index.index(for: m1.id) == nil)
        #expect(index.index(forToolCallId: "toolu_xyz") == nil)
    }

    @Test("index correct after bulk load via rebuild")
    func correctAfterBulkLoad() {
        let index = MessageIndex()
        var messages: [ChatMessage] = []
        for i in 0..<100 {
            if i % 10 == 0 {
                messages.append(makeToolMessage(toolCallId: "tool_\(i)"))
            } else {
                messages.append(makeMessage())
            }
        }

        index.rebuild(from: messages)

        for (i, msg) in messages.enumerated() {
            #expect(index.index(for: msg.id) == i)
        }

        #expect(index.index(forToolCallId: "tool_0") == 0)
        #expect(index.index(forToolCallId: "tool_50") == 50)
        #expect(index.index(forToolCallId: "tool_90") == 90)
    }

    @Test("didInsertAtFront shifts all existing indices")
    func insertAtFront() {
        let index = MessageIndex()
        let existing1 = makeMessage()
        let existing2 = makeMessage()

        index.didAppend(existing1, at: 0)
        index.didAppend(existing2, at: 1)

        let front1 = makeMessage()
        let front2 = makeMessage()
        index.didInsertAtFront(messages: [front1, front2], totalCount: 4)

        #expect(index.index(for: front1.id) == 0)
        #expect(index.index(for: front2.id) == 1)
        #expect(index.index(for: existing1.id) == 2)
        #expect(index.index(for: existing2.id) == 3)
    }
}
