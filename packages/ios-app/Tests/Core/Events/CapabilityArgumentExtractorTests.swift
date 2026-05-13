import XCTest
@testable import TronMobile

final class CapabilityArgumentExtractorTests: XCTestCase {

    // MARK: - Primary path: toolCall.arguments

    private func makeCapabilityInvocation(arguments: String) -> CapabilityInvocationStartedPayload? {
        CapabilityInvocationStartedPayload(from: [
            "invocationId": AnyCodable("tc1"),
            "name": AnyCodable("Read"),
            "modelToolName": AnyCodable("execute"),
            "arguments": AnyCodable(arguments),
            "turn": AnyCodable(1)
        ])
    }

    func testExtractsFromCapabilityInvocationArguments() {
        let toolCall = makeCapabilityInvocation(arguments: "{\"path\":\"/test.txt\"}")

        let result = CapabilityArgumentExtractor.extractArguments(
            toolCall: toolCall,
            contentBlock: [:]
        )

        XCTAssertEqual(result, "{\"path\":\"/test.txt\"}")
    }

    // MARK: - Fallback: contentBlock dict serialization

    func testExtractsFromContentBlockArgumentsDict() {
        let block: [String: Any] = [
            "arguments": ["path": "/test.txt"]
        ]

        let result = CapabilityArgumentExtractor.extractArguments(
            toolCall: nil,
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

        let result = CapabilityArgumentExtractor.extractArguments(
            toolCall: nil,
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

        let result = CapabilityArgumentExtractor.extractArguments(
            toolCall: nil,
            contentBlock: block
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("from_args"))
        XCTAssertFalse(result!.contains("from_input"))
    }

    // MARK: - Nil case

    func testReturnsNilWhenNoArguments() {
        let result = CapabilityArgumentExtractor.extractArguments(
            toolCall: nil,
            contentBlock: [:]
        )

        XCTAssertNil(result)
    }

    func testReturnsNilWhenContentBlockHasNonDictArguments() {
        let block: [String: Any] = [
            "arguments": "not a dict"
        ]

        let result = CapabilityArgumentExtractor.extractArguments(
            toolCall: nil,
            contentBlock: block
        )

        XCTAssertNil(result)
    }

    // MARK: - Edge cases

    func testEmptyDictReturnsEmptyJson() {
        let block: [String: Any] = [
            "arguments": [String: Any]()
        ]

        let result = CapabilityArgumentExtractor.extractArguments(
            toolCall: nil,
            contentBlock: block
        )

        XCTAssertEqual(result, "{}")
    }

    func testCapabilityInvocationArgumentsTakePriorityOverContentBlock() {
        let toolCall = makeCapabilityInvocation(arguments: "{\"from_tool_call\":true}")
        let block: [String: Any] = [
            "arguments": ["from_block": true]
        ]

        let result = CapabilityArgumentExtractor.extractArguments(
            toolCall: toolCall,
            contentBlock: block
        )

        XCTAssertEqual(result, "{\"from_tool_call\":true}")
    }
}
