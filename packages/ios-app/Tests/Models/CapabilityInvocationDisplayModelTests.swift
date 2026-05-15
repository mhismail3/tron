import XCTest
@testable import TronMobile

final class CapabilityInvocationDisplayModelTests: XCTestCase {

    func testSearchDisplaysPrimitiveThenQuery() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"query":"process run","includeUnavailable":true}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "search",
                contractId: "capability::search",
                implementationId: "first_party.capability.v1.search",
                functionId: "capability::search"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Search")
        XCTAssertEqual(invocation.display.commandText, "“process run”")
        XCTAssertEqual(invocation.display.requestRows.first?.label, "Query")
        XCTAssertEqual(invocation.display.requestRows.first?.value, "process run")
    }

    func testInspectDisplaysRequestedTarget() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"contractId":"process::run"}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "inspect",
                contractId: "capability::inspect",
                implementationId: "first_party.capability.v1.inspect",
                functionId: "capability::inspect"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Inspect")
        XCTAssertEqual(invocation.display.commandText, "process::run")
        XCTAssertEqual(invocation.display.targetId, "process::run")
    }

    func testExecuteDisplaysTargetAndCommandInsteadOfPrimitiveImplementation() {
        let invocation = testCapabilityInvocation(
            status: .error,
            arguments: #"{"contractId":"process::run","payload":{"command":"date +%s"},"expectedRevision":303}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "capability::execute",
                implementationId: "first_party.capability.v1.execute",
                functionId: "capability::execute"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Execute")
        XCTAssertEqual(invocation.display.targetId, "process::run")
        XCTAssertEqual(invocation.display.payloadSummary, "date +%s")
        XCTAssertEqual(invocation.display.commandText, "process::run · date +%s")
        XCTAssertEqual(invocation.display.requestRows.first?.label, "Capability")
        XCTAssertEqual(invocation.display.requestRows.first?.value, "process::run")
        XCTAssertFalse(invocation.display.commandText.contains("first_party.capability.v1.execute"))
    }

    func testExecuteChipSuppressesSessionWorktreeIdsForPathPayloads() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"contractId":"filesystem::list_dir","payload":{"path":"/Users/moose/Downloads/projects/testspace/.worktrees/session/sess_019e245a-408e-7331-9644-b46ade73be0d","showHidden":false},"mode":"invoke","reason":"Smoke-test list_dir."}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "capability::execute",
                implementationId: "first_party.capability.v1.execute",
                functionId: "capability::execute"
            )
        )

        XCTAssertEqual(invocation.display.commandText, "filesystem::list_dir · session worktree")
        XCTAssertFalse(invocation.display.commandText.contains("019e245a"))
        XCTAssertEqual(invocation.display.requestRows.map(\.label), ["Capability", "Mode", "Path", "Reason"])
    }

    func testExecuteResultHighlightsFilesystemOutput() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"contractId":"filesystem::find","payload":{"path":"/tmp/work","query":"package.json"}}"#,
            result: #"{"matches":[],"path":"/tmp/work","truncated":false}"#,
            details: [
                "output": AnyCodable([
                    "matches": [],
                    "path": "/tmp/work",
                    "truncated": false
                ]),
                "status": "ok"
            ],
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "filesystem::find",
                implementationId: "first_party.filesystem.v1.find",
                functionId: "filesystem::find",
                pluginId: "first_party.filesystem",
                trustTier: "first_party_signed"
            )
        )

        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Status", value: "Completed")))
        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Matches", value: "0")))
        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Path", value: "work")))
    }

    func testResolvedExecuteStillKeepsPrimitiveTitle() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"payload":{"command":"pwd"}}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "process::run",
                implementationId: "first_party.process.v1.run",
                functionId: "process::run",
                pluginId: "first_party.process",
                workerId: "process"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Execute")
        XCTAssertEqual(invocation.display.targetId, "process::run")
        XCTAssertEqual(invocation.display.commandText, "process::run · pwd")
    }

    func testPresentationClassifiesCapabilitySourceLabels() {
        let firstParty = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "process::run",
            implementationId: "first_party.process.v1.run",
            functionId: "process::run",
            pluginId: "first_party.process",
            trustTier: "first_party_signed"
        )
        let mcp = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "github::search_issues",
            implementationId: "mcp.github.search_issues",
            functionId: "github::search_issues",
            pluginId: "external_mcp.github",
            trustTier: "external_mcp"
        )

        XCTAssertEqual(CapabilityPresentation.sourceLabel(for: firstParty), "First-party")
        XCTAssertEqual(CapabilityPresentation.sourceLabel(for: mcp), "MCP")
    }
}
