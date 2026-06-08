import XCTest
@testable import TronMobile

@MainActor
final class SessionActivityStreamTests: XCTestCase {
    func testServerActivityLineUsesResolvedPresentationHints() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "operationName": "make_surface",
            "presentationHints": {
                "displayName": "Runtime surface",
                "summary": "Generated panel",
                "icon": "puzzlepiece.extension"
            },
            "capabilityArgs": {
                "resourceId": "surface/demo"
            },
            "durationMs": 150,
            "isError": false
        }
        """.data(using: .utf8)!

        let line = try JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()

        XCTAssertEqual(line.displayName, "Runtime surface")
        XCTAssertEqual(line.summary, "Generated panel")
        XCTAssertEqual(line.icon, "puzzlepiece.extension")
        XCTAssertEqual(line.duration, "150ms")
        XCTAssertFalse(line.summary?.contains("{") ?? false)
        XCTAssertEqual(line.capabilityIdentity?.operationName, "make_surface")
    }

    func testRuntimePathServerActivityLineUsesCompactPathSummary() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "operationName": "state_write",
            "capabilityArgs": {
                "path": "/Users/moose/Downloads/projects/tron"
            },
            "durationMs": 60600,
            "isError": true
        }
        """.data(using: .utf8)!

        let line = try JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()

        XCTAssertEqual(line.displayName, "State Write")
        XCTAssertEqual(line.summary, "tron")
        XCTAssertFalse(line.summary?.contains("/Users") ?? false)
    }

    func testRuntimeSessionActivityLinesUseGenericNames() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "operationName": "state_list",
            "durationMs": 147,
            "isError": false
        }
        """.data(using: .utf8)!

        let line = try JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()

        XCTAssertEqual(line.displayName, "State List")
        XCTAssertFalse(line.displayName?.contains("Worker") ?? false)
    }

    func testSessionStreamBufferAddsCapabilityStartFromIdentity() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            operationName: "state_read"
        )

        buffer.addCapabilityStart(
            identity: identity,
            invocationId: "call_read",
            arguments: ["path": AnyCodable("/tmp/example.txt")]
        )

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].modelPrimitiveName, "state_read")
        XCTAssertEqual(buffer.lines[0].displayName, "State Read")
        XCTAssertEqual(buffer.lines[0].icon, "play.circle")
        XCTAssertEqual(buffer.lines[0].capabilityIdentity, identity)
    }

    func testSessionStreamBufferSummarizesCapabilityArgumentsWithoutJson() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            operationName: "process_run"
        )

        buffer.addCapabilityStart(
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

    func testSessionStreamBufferAddsCapabilityEndWithNeutralPresentation() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            operationName: "process_run"
        )

        buffer.addCapabilityEnd(identity: identity, success: false, durationMs: 250)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].displayName, "Process Run")
        XCTAssertEqual(buffer.lines[0].icon, "play.circle")
        XCTAssertEqual(buffer.lines[0].iconColor, .tronInfo)
        XCTAssertEqual(buffer.lines[0].duration, "250ms")
        XCTAssertEqual(buffer.lines[0].capabilityIdentity, identity)
    }
}
