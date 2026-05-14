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
            arguments: #"{"capabilityId":"process::run"}"#,
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
            arguments: #"{"capabilityId":"process::run","payload":{"command":"date +%s"},"expectedRevision":303}"#,
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
        XCTAssertFalse(invocation.display.commandText.contains("first_party.capability.v1.execute"))
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
