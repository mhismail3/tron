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
        #expect(transcript.components(separatedBy: "LazyVStack(alignment: .leading, spacing: 0)").count - 1 == 1)
        #expect(transcript.components(separatedBy: "ForEach(ChatPhysicalTranscriptRowPolicy.rows(").count - 1 == 1)
        #expect(chat.components(separatedBy: ".safeAreaInset(edge: .bottom, spacing: 0)").count - 1 == 1)
        #expect(transcript.contains(".scrollPosition($scrollPosition)"))
        #expect(transcript.contains(".defaultScrollAnchor(.bottom, for: .initialOffset)"))
        #expect(transcript.contains(".defaultScrollAnchor(.bottom, for: .alignment)"))
        #expect(transcript.contains("for: .sizeChanges"))
        #expect(transcript.contains("scrollCoordinator.usesPinnedSizeChangeAnchor ? .bottom : .top"))
        #expect(!chat.contains("position.scrollTo(id: \"transcript-bottom\", anchor: .bottom)"))
        #expect(!chat.contains("ScrollPosition(idType: String.self, edge: .bottom)"))
        #expect(chat.contains("case .tail where command.origin == .physicalTailRepair"))
        #expect(chat.contains("|| command.origin == .tailMaterialization"))
        #expect(!chat.contains("case .renderedID"))
        #expect(!chat.contains("scrollTo(id: renderedID"))
        #expect(!transcript.contains(".id(displayed."))
        #expect(chat.components(separatedBy: "scrollTo(id: \"transcript-bottom\", anchor: .bottom)").count - 1 == 1)
        #expect(chat.components(separatedBy: "scrollTo(edge: .bottom)").count - 1 == 1)
        #expect(!chat.contains("scheduleTailFollow"))
        #expect(!chat.contains("tailFollowTask"))
        #expect(!chat.contains("ScrollViewReader"))
    }
}
