import XCTest
@testable import TronMobile

final class AgentMessagePresentationTests: XCTestCase {
    func testPresentationMakesSenderKindAndAuthorityExplicit() {
        let content = AgentMessageContent(
            messageId: "message-1",
            sourceAgentId: "agent-peer",
            sourceName: "Researcher",
            kind: "answer",
            authority: "peer",
            text: "Found it."
        )

        XCTAssertEqual(AgentMessagePresentation.sender(content), "Researcher")
        XCTAssertEqual(AgentMessagePresentation.label(content.kind), "Answer")
        XCTAssertEqual(AgentMessagePresentation.label(content.authority), "Peer")
        XCTAssertEqual(AgentMessagePresentation.accent(authority: content.authority), .peerMessage)
        XCTAssertEqual(AgentMessagePresentation.symbol(kind: content.kind), "bubble.left.and.text.bubble.right.fill")
    }

    func testPresentationKeepsUnknownFutureSemanticsReadable() {
        let content = AgentMessageContent(
            messageId: "message-2",
            sourceAgentId: "agent-new",
            kind: "review_request",
            authority: "future_manager",
            text: "Review this."
        )

        XCTAssertEqual(AgentMessagePresentation.sender(content), "agent-new")
        XCTAssertEqual(AgentMessagePresentation.label(content.kind), "Review Request")
        XCTAssertEqual(AgentMessagePresentation.accent(authority: content.authority), .unknown)
        XCTAssertEqual(AgentMessagePresentation.symbol(kind: content.kind), "bubble.left.fill")
    }
}

