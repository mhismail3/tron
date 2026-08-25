import Foundation
import Testing

@Suite("Chat scroll physical ownership guards")
struct ChatScrollOwnershipGuardTests {
    @Test("chat has one transcript, one composer inset, and one pinned size owner")
    func singlePhysicalOwner() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let transcript = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatTranscriptScrollView.swift"),
            encoding: .utf8
        )

        #expect(transcript.components(separatedBy: "ScrollView {").count - 1 == 1)
        #expect(chat.components(separatedBy: ".safeAreaInset(edge: .bottom, spacing: 0)").count - 1 == 1)
        #expect(transcript.contains(".scrollPosition($scrollPosition)"))
        #expect(!transcript.contains("for: .sizeChanges"))
        #expect(!chat.contains("scheduleTailFollow"))
        #expect(!chat.contains("tailFollowTask"))
        #expect(!chat.contains("ScrollViewReader"))
    }
}
