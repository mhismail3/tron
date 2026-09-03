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
        #expect(chat.contains("viewport.safeAreaInsets.bottom"))
        #expect(!transcript.contains("@State private var minimumUnderflowContentHeight"))
        #expect(!transcript.contains("minimumUnderflowContentHeight = minimumHeight"))
        #expect(transcript.contains(".defaultScrollAnchor(.bottom, for: .initialOffset)"))
        #expect(transcript.contains(".defaultScrollAnchor(.bottom, for: .alignment)"))
        #expect(transcript.contains("for: .sizeChanges"))
        #expect(transcript.contains("scrollCoordinator.usesPinnedSizeChangeAnchor ? .bottom : .top"))
        #expect(!chat.contains("position.scrollTo(id: \"transcript-bottom\", anchor: .bottom)"))
        #expect(!chat.contains("ScrollPosition(idType: String.self, edge: .bottom)"))
        #expect(chat.contains("case .tail where command.origin == .physicalTailRepair"))
        #expect(chat.contains("case .materialize(let renderedID)"))
        #expect(!chat.contains("case .renderedID"))
        #expect(chat.components(separatedBy: "target.scrollTo(id: renderedID, anchor: .bottom)").count - 1 == 1)
        #expect(!transcript.contains(".id(displayed."))
        #expect(chat.components(separatedBy: "scrollTo(id: \"transcript-bottom\", anchor: .bottom)").count - 1 == 1)
        #expect(chat.components(separatedBy: "scrollTo(edge: .bottom)").count - 1 == 1)
        #expect(chat.contains("layoutTransactionID: layoutGeneration"))
        #expect(chat.contains("onEntranceSettled: settleTranscriptEntrance"))
        #expect(!chat.contains("masksPinnedViewportResume"))
        #expect(!chat.contains("resumePinnedViewportPresentation"))
        #expect(!chat.contains("scheduleTailFollow"))
        #expect(!chat.contains("tailFollowTask"))
        #expect(!chat.contains("ScrollViewReader"))
    }

    @Test("submission changes responder state only after draft admission")
    func submissionAdmissionPrecedesResponderMutation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chat = try String(
            contentsOf: packageRoot.appending(path: "Sources/UI/Chat/ChatView.swift"),
            encoding: .utf8
        )
        let admission = try #require(chat.range(of: "let submission = try model.beginComposerSubmission("))
        let focus = try #require(chat.range(of: "composerFocused = false", range: admission.lowerBound..<chat.endIndex))
        #expect(admission.lowerBound < focus.lowerBound)
        let preceding = chat[..<admission.lowerBound]
        #expect(!preceding.suffix(2_000).contains("composerFocused = false"))
        #expect(!preceding.suffix(2_000).contains("resignFirstResponder()"))
    }
}
