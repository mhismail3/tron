import Foundation
import Testing
@testable import TronMobile

@Suite("Chat content entrance motion")
struct ChatContentTransitionTests {
    @Test("rendered roles select spatially consistent entrances")
    func entranceClassification() throws {
        let user = try transcriptItem(role: "user", id: "user")
        let assistant = try transcriptItem(role: "assistant", id: "assistant")
        let notification = ChatNotificationPresentation(
            id: "status",
            semanticID: nil,
            icon: "checkmark",
            title: "Ready",
            detail: nil,
            body: nil,
            tone: .accent,
            material: .flat
        )

        #expect(ChatContentEntranceKind.classify(.transcript(user)) == .userPrompt)
        #expect(ChatContentEntranceKind.classify(.transcript(assistant)) == .assistantContent)
        #expect(ChatContentEntranceKind.classify(.notification(notification)) == .centeredActivity)
    }

    @Test("user and queue content rises from the trailing composer edge")
    func composerEdgeMotion() {
        let user = ChatContentTransitionPolicy.hiddenTransform(
            for: .userPrompt,
            reduceMotion: false
        )
        let queued = ChatContentTransitionPolicy.hiddenTransform(
            for: .queuedPrompt,
            reduceMotion: false
        )

        #expect(user.anchor == .trailing)
        #expect(user.offsetX > 0)
        #expect(user.offsetY > 0)
        #expect(user.scale < 1)
        #expect(queued.anchor == .trailing)
        #expect(queued.offsetY >= user.offsetY)
    }

    @Test("activity remains role-aligned rather than flying across the transcript")
    func activityMotion() {
        let leading = ChatContentTransitionPolicy.hiddenTransform(
            for: .leadingActivity,
            reduceMotion: false
        )
        let centered = ChatContentTransitionPolicy.hiddenTransform(
            for: .centeredActivity,
            reduceMotion: false
        )

        #expect(leading.anchor == .leading)
        #expect(leading.offsetX < 0)
        #expect(centered.anchor == .center)
        #expect(centered.offsetX == 0)
    }

    @Test("Reduce Motion removes every spatial entrance component")
    func reduceMotion() {
        let kinds: [ChatContentEntranceKind] = [
            .userPrompt, .assistantContent, .leadingActivity, .centeredActivity, .queuedPrompt,
        ]
        for kind in kinds {
            #expect(ChatContentTransitionPolicy.hiddenTransform(
                for: kind,
                reduceMotion: true
            ) == .identity)
        }
    }

    private func transcriptItem(role: String, id: String) throws -> TranscriptItem {
        let data = Data(#"{"id":"\#(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"\#(role)","content":[{"id":"\#(id):0","type":"text","text":"hello"}]}"#.utf8)
        return try JSONDecoder.gateway.decode(TranscriptItem.self, from: data)
    }
}
