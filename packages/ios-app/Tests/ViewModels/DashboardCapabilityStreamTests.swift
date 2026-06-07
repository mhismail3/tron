import XCTest
@testable import TronMobile

@MainActor
final class DashboardCapabilityStreamTests: XCTestCase {
    func testServerActivityLineUsesResolvedPresentationHints() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "contractId": "runtime::make_surface",
            "implementationId": "runtime.surface.v1.make",
            "functionId": "runtime::make_surface",
            "pluginId": "runtime.surface",
            "workerId": "runtime",
            "catalogRevision": 42,
            "trustTier": "runtime",
            "riskLevel": "High",
            "effectClass": "ExternalSideEffect",
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
        XCTAssertEqual(line.capabilityIdentity?.contractId, "runtime::make_surface")
    }

    func testRuntimePathServerActivityLineUsesCompactPathSummary() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "contractId": "runtime::state_write",
            "implementationId": "runtime.state.v1.write",
            "functionId": "runtime::state_write",
            "pluginId": "runtime.state",
            "workerId": "runtime",
            "catalogRevision": 42,
            "trustTier": "runtime",
            "riskLevel": "Medium",
            "effectClass": "DelegatedInvocation",
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

    func testRuntimeDashboardLinesUseGenericNames() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "contractId": "runtime::list_state",
            "implementationId": "runtime.state.v1.list",
            "functionId": "runtime::list_state",
            "pluginId": "runtime.state",
            "workerId": "runtime",
            "catalogRevision": 42,
            "trustTier": "runtime",
            "riskLevel": "Low",
            "effectClass": "PureRead",
            "durationMs": 147,
            "isError": false
        }
        """.data(using: .utf8)!

        let line = try JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()

        XCTAssertEqual(line.displayName, "List State")
        XCTAssertFalse(line.displayName?.contains("Worker") ?? false)
    }

    func testSessionStreamBufferAddsCapabilityStartFromIdentity() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "runtime::read_state",
            implementationId: "runtime.state.v1.read",
            functionId: "runtime::read_state"
        )

        buffer.addCapabilityStart(
            identity: identity,
            invocationId: "call_read",
            arguments: ["path": AnyCodable("/tmp/example.txt")]
        )

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].modelPrimitiveName, "runtime::read_state")
        XCTAssertEqual(buffer.lines[0].displayName, "Read State")
        XCTAssertEqual(buffer.lines[0].icon, "play.circle")
        XCTAssertEqual(buffer.lines[0].capabilityIdentity, identity)
    }

    func testSessionStreamBufferSummarizesCapabilityArgumentsWithoutJson() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "runtime::run",
            implementationId: "runtime.action.v1.run",
            functionId: "runtime::run"
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
        XCTAssertEqual(buffer.lines[0].displayName, "Run")
        XCTAssertEqual(buffer.lines[0].summary, "git status --short --branch")
        XCTAssertFalse(buffer.lines[0].summary?.contains("{") ?? false)
    }

    func testSessionStreamBufferAddsCapabilityEndWithRiskAwarePresentation() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "runtime::run",
            implementationId: "runtime.action.v1.run",
            functionId: "runtime::run"
        )

        buffer.addCapabilityEnd(identity: identity, success: false, durationMs: 250)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].displayName, "Run")
        XCTAssertEqual(buffer.lines[0].icon, "play.circle")
        XCTAssertEqual(buffer.lines[0].iconColor, .tronInfo)
        XCTAssertEqual(buffer.lines[0].duration, "250ms")
        XCTAssertEqual(buffer.lines[0].capabilityIdentity, identity)
    }
}
