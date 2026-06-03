import XCTest
@testable import TronMobile

@MainActor
final class DashboardCapabilityStreamTests: XCTestCase {
    func testServerActivityLineUsesResolvedPresentationHints() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "contractId": "worker::spawn",
            "implementationId": "first_party.worker.v1.spawn",
            "functionId": "worker::spawn",
            "pluginId": "first_party.worker",
            "workerId": "worker",
            "catalogRevision": 42,
            "trustTier": "first_party_signed",
            "riskLevel": "High",
            "effectClass": "ExternalSideEffect",
            "presentationHints": {
                "displayName": "Local capability",
                "summary": "Safe in this workspace",
                "icon": "puzzlepiece.extension"
            },
            "capabilityArgs": {
                "visibility": "workspace",
                "expectedFunctionIds": ["disposable::hello"]
            },
            "durationMs": 150,
            "isError": false
        }
        """.data(using: .utf8)!

        let line = try JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()

        XCTAssertEqual(line.displayName, "Local capability")
        XCTAssertEqual(line.summary, "Safe in this workspace")
        XCTAssertEqual(line.icon, "puzzlepiece.extension")
        XCTAssertEqual(line.duration, "150ms")
        XCTAssertFalse(line.summary?.contains("{") ?? false)
        XCTAssertEqual(line.capabilityIdentity?.contractId, "worker::spawn")
    }

    func testWorkspaceAutonomyServerActivityLineUsesPlainCurrentWorkspaceSummary() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "contractId": "self_extension::grant_workspace_autonomy",
            "implementationId": "first_party.self_extension.v1.grant_workspace_autonomy",
            "functionId": "self_extension::grant_workspace_autonomy",
            "pluginId": "first_party.capability",
            "workerId": "capability",
            "catalogRevision": 42,
            "trustTier": "first_party_signed",
            "riskLevel": "Medium",
            "effectClass": "DelegatedInvocation",
            "capabilityArgs": {
                "workspacePath": "/Users/moose/Downloads/projects/tron",
                "reason": "Approve workspace-local disposable helper capability work only"
            },
            "durationMs": 60600,
            "isError": true
        }
        """.data(using: .utf8)!

        let line = try JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()

        XCTAssertEqual(line.displayName, "Allow local capability work")
        XCTAssertEqual(line.summary, "Current workspace")
        XCTAssertFalse(line.summary?.contains("/Users") ?? false)
        XCTAssertFalse(line.summary?.contains("reason") ?? false)
        XCTAssertFalse(line.displayName?.contains("Grant") ?? false)
    }

    func testSandboxHelperDashboardLinesDoNotExposeSpawnedWorkerVocabulary() throws {
        let data = """
        {
            "kind": "capability",
            "modelPrimitiveName": "execute",
            "contractId": "sandbox::list_spawned_workers",
            "implementationId": "first_party.sandbox.v1.list_spawned_workers",
            "functionId": "sandbox::list_spawned_workers",
            "pluginId": "first_party.sandbox",
            "workerId": "sandbox",
            "catalogRevision": 42,
            "trustTier": "first_party_signed",
            "riskLevel": "Low",
            "effectClass": "PureRead",
            "durationMs": 147,
            "isError": false
        }
        """.data(using: .utf8)!

        let line = try JSONDecoder().decode(ServerActivityLine.self, from: data).toActivityLine()

        XCTAssertEqual(line.displayName, "Check helper capabilities")
        XCTAssertFalse(line.displayName?.contains("Spawned") ?? false)
        XCTAssertFalse(line.displayName?.contains("Worker") ?? false)
    }

    func testSessionStreamBufferAddsCapabilityStartFromIdentity() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "filesystem::read_file",
            implementationId: "first_party.filesystem.v1.read_file",
            functionId: "filesystem::read_file"
        )

        buffer.addCapabilityStart(
            identity: identity,
            invocationId: "call_read",
            arguments: ["path": AnyCodable("/tmp/example.txt")]
        )

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].modelPrimitiveName, "filesystem::read_file")
        XCTAssertEqual(buffer.lines[0].displayName, "Read File")
        XCTAssertEqual(buffer.lines[0].icon, "doc.text.magnifyingglass")
        XCTAssertEqual(buffer.lines[0].capabilityIdentity, identity)
    }

    func testSessionStreamBufferSummarizesCapabilityArgumentsWithoutJson() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "process::run",
            implementationId: "first_party.process.v1.run",
            functionId: "process::run"
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
        XCTAssertEqual(buffer.lines[0].displayName, "Run Command")
        XCTAssertEqual(buffer.lines[0].summary, "git status --short --branch")
        XCTAssertFalse(buffer.lines[0].summary?.contains("{") ?? false)
    }

    func testSessionStreamBufferAddsCapabilityEndWithRiskAwarePresentation() {
        var buffer = SessionStreamBuffer()
        let identity = testCapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "process::run",
            implementationId: "first_party.process.v1.run",
            functionId: "process::run"
        )

        buffer.addCapabilityEnd(identity: identity, success: false, durationMs: 250)

        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines[0].displayName, "Run Command")
        XCTAssertEqual(buffer.lines[0].icon, "terminal")
        XCTAssertEqual(buffer.lines[0].iconColor, .tronInfo)
        XCTAssertEqual(buffer.lines[0].duration, "250ms")
        XCTAssertEqual(buffer.lines[0].capabilityIdentity, identity)
    }
}
