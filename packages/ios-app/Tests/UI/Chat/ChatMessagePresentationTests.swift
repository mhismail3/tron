import Foundation
import XCTest
@testable import TronMobile

final class ChatMessagePresentationTests: XCTestCase {
    func testOnlyCompletedFinalAssistantTextExposesMetadata() {
        let finalText = ChatMessage(
            role: .assistant,
            content: .text("Done"),
            model: "claude-sonnet-4",
            latencyMs: 750,
            isFinalAssistantResponse: true
        )
        let intermediateText = ChatMessage(
            role: .assistant,
            content: .text("I will inspect that"),
            model: "claude-sonnet-4",
            latencyMs: 750
        )
        let streamingText = ChatMessage(
            role: .assistant,
            content: .streaming("Done"),
            model: "claude-sonnet-4",
            latencyMs: 750,
            isFinalAssistantResponse: true
        )
        let thinking = ChatMessage(
            role: .assistant,
            content: .thinking(
                visible: "Checking",
                isExpanded: false,
                isStreaming: false,
                kind: .thinking
            ),
            model: "claude-sonnet-4",
            latencyMs: 750,
            isFinalAssistantResponse: true
        )
        let user = ChatMessage(
            role: .user,
            content: .text("Done"),
            model: "claude-sonnet-4",
            latencyMs: 750,
            isFinalAssistantResponse: true
        )

        XCTAssertNotNil(finalText.finalAssistantResponseMetadata)
        XCTAssertNil(intermediateText.finalAssistantResponseMetadata)
        XCTAssertNil(streamingText.finalAssistantResponseMetadata)
        XCTAssertNil(thinking.finalAssistantResponseMetadata)
        XCTAssertNil(user.finalAssistantResponseMetadata)
    }

    func testMetadataApplicationRequiresProjectedFinality() {
        var intermediate = ChatMessage(
            role: .assistant,
            content: .text("I will inspect that")
        )
        intermediate.applyFinalAssistantResponseMetadata(
            tokenRecord: nil,
            model: "claude-sonnet-4",
            latencyMs: 750
        )

        var final = ChatMessage(
            role: .assistant,
            content: .streaming("Done"),
            isStreaming: true,
            isFinalAssistantResponse: true
        )
        final.applyFinalAssistantResponseMetadata(
            tokenRecord: nil,
            model: "claude-sonnet-4",
            latencyMs: 750
        )

        XCTAssertNil(intermediate.model)
        XCTAssertNil(intermediate.latencyMs)
        XCTAssertEqual(final.model, "claude-sonnet-4")
        XCTAssertEqual(final.latencyMs, 750)
        XCTAssertNil(final.finalAssistantResponseMetadata)

        final.content = .text("Done")
        final.isStreaming = false
        XCTAssertNotNil(final.finalAssistantResponseMetadata)
    }

    func testChatContentSourcesHaveNoLeadingResponseOrThinkingRails() throws {
        let textSource = try source("Sources/UI/Chat/Messages/TextContentView.swift")
        let streamingSource = try source("Sources/UI/Chat/Messages/StreamingContentView.swift")
        let thinkingSource = try source("Sources/UI/Chat/Messages/ThinkingContentView.swift")

        XCTAssertFalse(textSource.contains(".fill(Color.tronEmerald)"))
        XCTAssertFalse(streamingSource.contains("accentLine"))
        XCTAssertFalse(streamingSource.contains(".frame(width: 2)"))
        XCTAssertFalse(thinkingSource.contains(".frame(width: 2)"))
    }

    func testThinkingPresentationPreservesSeparateSummaryParagraphsWithoutBoldMarkup() {
        let content = """
        **Planning schema validation worker**

        **Investigating internal schema test endpoint**
        """

        XCTAssertEqual(
            ThinkingTextPresentation.displayText(content),
            "Planning schema validation worker\n\nInvestigating internal schema test endpoint"
        )
        XCTAssertEqual(
            ThinkingTextPresentation.previewText(content),
            "Planning schema validation worker\nInvestigating internal schema test endpoint"
        )
    }

    func testThinkingPresentationDoesNotFlattenProviderListsOrInlinePunctuation() {
        let content = """
        # Review
        - First item
          - Nested item with `code` and 2 * 3
        """

        XCTAssertEqual(
            ThinkingTextPresentation.displayText(content),
            "Review\n- First item\n  - Nested item with `code` and 2 * 3"
        )
    }

    func testMessageBubbleUsesFinalResponsePolicyForItsOnlyMetadataFooter() throws {
        let source = try source("Sources/UI/Chat/Messages/MessageBubble.swift")

        XCTAssertTrue(source.contains("message.finalAssistantResponseMetadata"))
        XCTAssertFalse(source.contains("hasMetadata"))
        XCTAssertFalse(source.contains("else if let record = message.tokenRecord"))
    }

    func testStreamingRevealFadesOnlyTheNewCharacterTailAndConverges() {
        let stableOpacity = StreamingTextRevealPolicy.opacity(
            forCharacterAt: 99,
            lineCharacterCount: 104,
            targetCharacterCount: 104,
            revealedCharacterCount: 100,
            reduceMotion: false
        )
        let firstNewCharacterOpacity = StreamingTextRevealPolicy.opacity(
            forCharacterAt: 100,
            lineCharacterCount: 104,
            targetCharacterCount: 104,
            revealedCharacterCount: 100,
            reduceMotion: false
        )
        let halfwayOpacity = StreamingTextRevealPolicy.opacity(
            forCharacterAt: 102,
            lineCharacterCount: 104,
            targetCharacterCount: 104,
            revealedCharacterCount: 102.5,
            reduceMotion: false
        )
        let settledOpacity = StreamingTextRevealPolicy.opacity(
            forCharacterAt: 103,
            lineCharacterCount: 104,
            targetCharacterCount: 104,
            revealedCharacterCount: 104,
            reduceMotion: false
        )

        XCTAssertEqual(stableOpacity, 1)
        XCTAssertEqual(firstNewCharacterOpacity, StreamingTextRevealPolicy.minimumOpacity)
        XCTAssertEqual(
            halfwayOpacity,
            StreamingTextRevealPolicy.minimumOpacity
                + ((1 - StreamingTextRevealPolicy.minimumOpacity) * 0.5),
            accuracy: 0.000_1
        )
        XCTAssertEqual(settledOpacity, 1)
    }

    func testStreamingRevealIsBoundedAndHonorsReduceMotion() {
        let beforeBoundedTail = StreamingTextRevealPolicy.opacity(
            forCharacterAt: 975,
            lineCharacterCount: 1_000,
            targetCharacterCount: 1_000,
            revealedCharacterCount: 0,
            reduceMotion: false
        )
        let firstBoundedTailCharacter = StreamingTextRevealPolicy.opacity(
            forCharacterAt: 976,
            lineCharacterCount: 1_000,
            targetCharacterCount: 1_000,
            revealedCharacterCount: 0,
            reduceMotion: false
        )
        let reducedMotionOpacity = StreamingTextRevealPolicy.opacity(
            forCharacterAt: 999,
            lineCharacterCount: 1_000,
            targetCharacterCount: 1_000,
            revealedCharacterCount: 0,
            reduceMotion: true
        )

        XCTAssertEqual(beforeBoundedTail, 1)
        XCTAssertEqual(firstBoundedTailCharacter, StreamingTextRevealPolicy.minimumOpacity)
        XCTAssertEqual(reducedMotionOpacity, 1)
    }

    func testStreamingRevealDoesNotAnimateBackwardReplacement() {
        let opacity = StreamingTextRevealPolicy.opacity(
            forCharacterAt: 0,
            lineCharacterCount: 1,
            targetCharacterCount: 4,
            revealedCharacterCount: 8,
            reduceMotion: false
        )

        XCTAssertEqual(opacity, 1)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: iosAppRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private var iosAppRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
