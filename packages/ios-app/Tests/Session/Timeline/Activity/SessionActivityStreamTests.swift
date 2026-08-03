import XCTest
@testable import TronMobile

@MainActor
final class SessionActivityStreamTests: XCTestCase {
    func testServerActivityLineUsesResolvedPresentationHints() throws {
        let data = """
        {
            "kind": "tool",
            "toolName": "process_run",
            "presentationHints": {
                "displayName": "Runtime surface",
                "summary": "Generated panel",
                "icon": "puzzlepiece.extension"
            },
            "toolArgs": {
                "resourceId": "surface/demo"
            },
            "durationMs": 150,
            "isError": false
        }
        """.data(using: .utf8)!

        let line = try XCTUnwrap(
            JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()
        )

        XCTAssertEqual(line.displayName, "Runtime surface")
        XCTAssertEqual(line.summary, "Generated panel")
        XCTAssertEqual(line.icon, "puzzlepiece.extension")
        XCTAssertEqual(line.duration, "150ms")
        XCTAssertFalse(line.summary?.contains("{") ?? false)
    }

    func testRuntimePathServerActivityLineUsesCompactPathSummary() throws {
        let data = """
        {
            "kind": "tool",
            "toolName": "state_write",
            "toolArgs": {
                "path": "/tmp/tron-fixtures/tron"
            },
            "durationMs": 60600,
            "isError": true
        }
        """.data(using: .utf8)!

        let line = try XCTUnwrap(
            JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()
        )

        XCTAssertEqual(line.displayName, "State Write")
        XCTAssertEqual(line.summary, "tron")
        XCTAssertFalse(line.summary?.contains("/Users") ?? false)
    }

    func testRuntimeSessionActivityLinesUseGenericNames() throws {
        let data = """
        {
            "kind": "tool",
            "toolName": "state_list",
            "durationMs": 147,
            "isError": false
        }
        """.data(using: .utf8)!

        let line = try XCTUnwrap(
            JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()
        )

        XCTAssertEqual(line.displayName, "State List")
        XCTAssertFalse(line.displayName?.contains("Worker") ?? false)
    }

    func testSessionStreamBufferAddsToolStartFromIdentity() {
        var buffer = SessionStreamBuffer()
        let identity = testToolIdentity(
            toolName: "state_read",
        )

        buffer.addToolStart(
            identity: identity,
            invocationId: "call_read",
            arguments: ["path": AnyCodable("/tmp/example.txt")]
        )

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].toolName, "state_read")
        XCTAssertEqual(buffer.lines[0].displayName, "State Read")
        XCTAssertEqual(buffer.lines[0].icon, "play.circle")
        XCTAssertEqual(buffer.lines[0].toolIdentity, identity)
    }

    func testSessionStreamBufferSummarizesToolArgumentsWithoutJson() {
        var buffer = SessionStreamBuffer()
        let identity = testToolIdentity(
            toolName: "process_run",
        )

        buffer.addToolStart(
            identity: identity,
            invocationId: "call_process",
            arguments: [
                "command": AnyCodable("git status --short --branch"),
                "executionMode": AnyCodable("read_only")
            ]
        )

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].displayName, "Process Run")
        XCTAssertEqual(buffer.lines[0].summary, "git status --short --branch")
        XCTAssertFalse(buffer.lines[0].summary?.contains("{") ?? false)
    }

    func testSessionStreamBufferAddsToolEndWithNeutralPresentation() {
        var buffer = SessionStreamBuffer()
        let identity = testToolIdentity(
            toolName: "process_run",
        )

        buffer.addToolEnd(identity: identity, success: false, durationMs: 250)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].displayName, "Process Run")
        XCTAssertEqual(buffer.lines[0].icon, "play.circle")
        XCTAssertEqual(buffer.lines[0].iconColor, .tronInfo)
        XCTAssertEqual(buffer.lines[0].duration, "250ms")
        XCTAssertEqual(buffer.lines[0].toolIdentity, identity)
    }
}
