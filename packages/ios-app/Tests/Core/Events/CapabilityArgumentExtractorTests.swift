import XCTest
@testable import TronMobile

final class CapabilityArgumentExtractorTests: XCTestCase {

    // MARK: - Primary path: invocationStart.arguments

    private func makeCapabilityInvocation(arguments: String) -> CapabilityInvocationStartedPayload? {
        CapabilityInvocationStartedPayload(from: [
            "invocationId": AnyCodable("tc1"),
            "modelPrimitiveName": AnyCodable("execute"),
            "arguments": AnyCodable(arguments),
            "turn": AnyCodable(1)
        ])
    }

    func testExtractsFromCapabilityInvocationArguments() {
        let invocationStart = makeCapabilityInvocation(arguments: "{\"path\":\"/test.txt\"}")

        let result = CapabilityArgumentExtractor.extractArguments(
            invocationStart: invocationStart,
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

        let result = CapabilityArgumentExtractor.extractArguments(
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

        let result = CapabilityArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: block
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("from_args"))
        XCTAssertFalse(result!.contains("from_input"))
    }

    // MARK: - Nil case

    func testReturnsNilWhenNoArguments() {
        let result = CapabilityArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: [:]
        )

        XCTAssertNil(result)
    }

    func testReturnsNilWhenContentBlockHasNonDictArguments() {
        let block: [String: Any] = [
            "arguments": "not a dict"
        ]

        let result = CapabilityArgumentExtractor.extractArguments(
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

        let result = CapabilityArgumentExtractor.extractArguments(
            invocationStart: nil,
            contentBlock: block
        )

        XCTAssertEqual(result, "{}")
    }

    func testCapabilityInvocationArgumentsTakePriorityOverContentBlock() {
        let invocationStart = makeCapabilityInvocation(arguments: "{\"from_capability_invocation\":true}")
        let block: [String: Any] = [
            "arguments": ["from_block": true]
        ]

        let result = CapabilityArgumentExtractor.extractArguments(
            invocationStart: invocationStart,
            contentBlock: block
        )

        XCTAssertEqual(result, "{\"from_capability_invocation\":true}")
    }
}
