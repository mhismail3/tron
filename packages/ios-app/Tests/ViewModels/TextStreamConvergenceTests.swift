import XCTest
@testable import TronMobile

/// M13 — Live streaming and reconstruction must converge on the same
/// final string for the same assistant message. Two separate code paths
/// produce the `.text(String)` ChatMessage content:
///
/// 1. **Live**: `StreamingManager.handleTextDelta` accumulates server
///    text_delta events into `receivedText`, then
///    `finalizeStreamingMessage` trims with `.whitespacesAndNewlines`.
///
/// 2. **Reconstruction**: `AssistantMessagePayload.textContent` joins
///    text content blocks from the persisted `message.assistant` event
///    and trims with `.whitespacesAndNewlines`.
///
/// These paths look independent, but divergence would produce the
/// visible bug of "my streaming message reads slightly differently
/// after I reconnect and reconstruction replaces it." The plan
/// proposed extracting a shared `TextStreamAggregator`; investigation
/// found divergence cannot occur because:
///
/// - Both paths apply identical `.whitespacesAndNewlines` trimming.
/// - The reconstruction dedup in `ChatViewModel+Reconstruction.swift`
///   explicitly tests both `existing == trimmed || existing == text`
///   so any residual whitespace mismatch is absorbed.
/// - There's no live plugin for `message.assistant`; it's persisted
///   once and read by reconstruction only.
///
/// These tests codify the convergence invariant so a future change to
/// EITHER path's trimming rule trips the regression.
@MainActor
final class TextStreamConvergenceTests: XCTestCase {

    // MARK: - Helpers

    /// Feed a sequence of text_delta strings through StreamingManager and
    /// return the final text that finalizeStreamingMessage produces.
    private func runLiveStream(_ deltas: [String]) -> String {
        let manager = StreamingManager()
        manager.onCreateStreamingMessage = { UUID() }
        for delta in deltas {
            _ = manager.handleTextDelta(delta)
        }
        return manager.finalizeStreamingMessage()
    }

    /// Build a server-shaped AssistantMessagePayload with a single text
    /// content block and return its extracted textContent.
    private func serverTextContent(_ text: String) -> String? {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "text", "text": text]
            ])
        ]
        return AssistantMessagePayload(from: payload).textContent
    }

    // MARK: - Convergence

    func testLiveAndServerProduceIdenticalFinalTextForSimpleStream() {
        let live = runLiveStream(["Hello", " ", "World"])
        let server = serverTextContent("Hello World")
        XCTAssertEqual(live, server)
        XCTAssertEqual(live, "Hello World")
    }

    func testBothPathsStripTrailingWhitespace() {
        let live = runLiveStream(["answer:", " 42", "   \n\n"])
        let server = serverTextContent("answer: 42   \n\n")
        XCTAssertEqual(live, server, "trailing whitespace must trim identically")
        XCTAssertEqual(live, "answer: 42")
    }

    func testBothPathsStripLeadingNewlinesLiveViaFirstDeltaStrip() {
        // StreamingManager drops leading newlines from the very first
        // delta (StreamingManager.swift:197); finalize then trims all
        // leading + trailing whitespace. The server path's
        // textContent also trims `.whitespacesAndNewlines` from the
        // joined text, so the result converges.
        let live = runLiveStream(["\n\n\n", "Hello"])
        let server = serverTextContent("Hello")
        XCTAssertEqual(live, server)
        XCTAssertEqual(live, "Hello")
    }

    func testEmptyDeltaStreamFinalizesToEmpty() {
        let live = runLiveStream([])
        XCTAssertEqual(live, "", "no deltas → finalize returns empty string")
    }

    func testWhitespaceOnlyDeltasProduceEmptyLiveText() {
        // StreamingManager drops leading newlines from the first
        // non-empty delta but will still flush if subsequent whitespace
        // arrives. On finalize, `.whitespacesAndNewlines` trimming
        // reduces the whole stream back to empty.
        let live = runLiveStream(["   ", "\n\n", "\t"])
        let server = serverTextContent("   \n\n\t")
        XCTAssertEqual(live, server ?? "")
    }

    // MARK: - Server payload shape

    func testServerExtractsOnlyTextBlocksSkippingToolUse() {
        // When the server emits message.assistant with interleaved
        // text + tool_use blocks, textContent returns only the text.
        // Tool_use blocks render via tool.call events (handled live by
        // a different plugin); they MUST NOT contribute to the text
        // message otherwise the live path (which does NOT include
        // tool_use in receivedText) would diverge.
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "text", "text": "Before tool."],
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["cmd": "ls"]],
                ["type": "text", "text": "After tool."],
            ])
        ]
        let server = AssistantMessagePayload(from: payload).textContent
        // Text blocks join with newline separator, then trim.
        XCTAssertEqual(server, "Before tool.\nAfter tool.")
    }

    func testServerReturnsNilWhenContentHasNoTextBlocks() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "tool_use", "id": "t1", "name": "Bash", "input": [:] as [String: String]]
            ])
        ]
        XCTAssertNil(AssistantMessagePayload(from: payload).textContent)
    }

    // MARK: - Trimming semantics

    /// The single most important invariant: IF either path changes
    /// its trimming rule (e.g. someone removes the `.whitespacesAndNewlines`
    /// call), this test fires. Live uses `.whitespacesAndNewlines`
    /// (StreamingManager.swift:241); server uses the same set
    /// (MessagePayloads.swift:169).
    func testTrimmingSemanticsMatchAcrossPaths() {
        // Every codepoint in .whitespacesAndNewlines has to be stripped
        // by both. Sample a few at both ends — regular space, tab,
        // newline, carriage return.
        for (raw, expected) in [
            (" hello ", "hello"),
            ("\thello\t", "hello"),
            ("\nhello\n", "hello"),
            ("\r\nhello\r\n", "hello"),
            (" \t\n hello \n\t ", "hello"),
        ] {
            let live = runLiveStream([raw])
            let server = serverTextContent(raw)
            XCTAssertEqual(live, expected, "live failed to trim: '\(raw.debugDescription)'")
            XCTAssertEqual(server, expected, "server failed to trim: '\(raw.debugDescription)'")
            XCTAssertEqual(live, server, "live/server diverged on: '\(raw.debugDescription)'")
        }
    }
}
