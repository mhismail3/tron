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

    func testMessageBubbleUsesFinalResponsePolicyForItsOnlyMetadataFooter() throws {
        let source = try source("Sources/UI/Chat/Messages/MessageBubble.swift")

        XCTAssertTrue(source.contains("message.finalAssistantResponseMetadata"))
        XCTAssertFalse(source.contains("hasMetadata"))
        XCTAssertFalse(source.contains("else if let record = message.tokenRecord"))
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
