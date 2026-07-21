import XCTest
@testable import TronMobile

final class ToolArgumentExtractorTests: XCTestCase {

    // MARK: - Primary path: invocationStart.arguments

    private func makeToolInvocation(arguments: String) -> ToolInvocationStartedPayload? {
        ToolInvocationStartedPayload(from: [
            "invocationId": AnyCodable("tc1"),
            "toolName": AnyCodable("process_run"),
            "arguments": AnyCodable(arguments),
            "turn": AnyCodable(1)
        ])
    }

    func testExtractsFromToolInvocationArguments() {
        let invocationStart = makeToolInvocation(arguments: "{\"path\":\"/test.txt\"}")

        let result = ToolArgumentExtractor.extractArguments(
            invocationStart: invocationStart,
            contentBlock: [:]
        )

        XCTAssertEqual(result, "{\"path\":\"/test.txt\"}")
    }

    // MARK: - Content-block Dictionary Serialization

    func testExtractsFromContentBlockArgumentsDict() {
        let block: [String: Any] = [
            "arguments": ["path": "/test.txt"]
        ]

        let result = ToolArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: block
        )

        XCTAssertNotNil(result)
        // sortedKeys ensures deterministic output
        XCTAssertTrue(result!.contains("path"))
        XCTAssertTrue(result!.contains("/test.txt"))
    }

    func testExtractsFromContentBlockInputDict() {
        let block: [String: Any] = [
            "input": ["command": "ls"]
        ]

        let result = ToolArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: block
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("command"))
    }

    func testPrefersArgumentsOverInput() {
        let block: [String: Any] = [
            "arguments": ["from_args": true],
            "input": ["from_input": true]
        ]

        let result = ToolArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: block
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("from_args"))
        XCTAssertFalse(result!.contains("from_input"))
    }

    // MARK: - Nil case

    func testReturnsNilWhenNoArguments() {
        let result = ToolArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: [:]
        )

        XCTAssertNil(result)
    }

    func testReturnsNilWhenContentBlockHasNonDictArguments() {
        let block: [String: Any] = [
            "arguments": "not a dict"
        ]

        let result = ToolArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: block
        )

        XCTAssertNil(result)
    }

    // MARK: - Edge cases

    func testEmptyDictReturnsEmptyJson() {
        let block: [String: Any] = [
            "arguments": [String: Any]()
        ]

        let result = ToolArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: block
        )

        XCTAssertEqual(result, "{}")
    }

    func testToolInvocationArgumentsTakePriorityOverContentBlock() {
        let invocationStart = makeToolInvocation(arguments: "{\"from_tool_invocation\":true}")
        let block: [String: Any] = [
            "arguments": ["from_block": true]
        ]

        let result = ToolArgumentExtractor.extractArguments(
            invocationStart: invocationStart,
            contentBlock: block
        )

        XCTAssertEqual(result, "{\"from_tool_invocation\":true}")
    }
}
