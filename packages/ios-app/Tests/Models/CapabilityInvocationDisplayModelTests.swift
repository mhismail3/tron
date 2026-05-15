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
        XCTAssertEqual(invocation.display.commandText, "Run Command")
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
        XCTAssertEqual(invocation.display.capabilityName, "Run Command")
        XCTAssertEqual(invocation.display.commandText, "date +%s")
        XCTAssertEqual(invocation.display.requestRows.first?.label, "Command")
        XCTAssertEqual(invocation.display.requestRows.first?.value, "date +%s")
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

        XCTAssertEqual(invocation.display.commandText, "session worktree")
        XCTAssertFalse(invocation.display.commandText.contains("019e245a"))
        XCTAssertEqual(invocation.display.requestRows.map(\.label), ["Path", "Reason"])
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

        XCTAssertTrue(invocation.display.resultRows.isEmpty)
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Match count", value: "0", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Result path", value: "work", isTechnical: true)))
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
        XCTAssertEqual(invocation.display.capabilityName, "Run Command")
        XCTAssertEqual(invocation.display.commandText, "pwd")
    }

    func testDurationPrefersObservedInvocationSpanWhenLongerThanServerDuration() {
        let started = Date(timeIntervalSince1970: 1_000)
        let completed = started.addingTimeInterval(2.4)
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"contractId":"process::run","payload":{"command":"date"}}"#,
            durationMs: 80,
            startedAt: started,
            completedAt: completed,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "process::run",
                implementationId: "first_party.process.v1.run",
                functionId: "process::run",
                pluginId: "first_party.process",
                trustTier: "first_party_signed"
            )
        )

        XCTAssertEqual(invocation.formattedDuration, "2.4s")
        XCTAssertEqual(invocation.serverFormattedDuration, "80ms")
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Server duration", value: "80ms", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Observed duration", value: "2.4s", isTechnical: true)))
    }

    func testUnknownThirdPartyCapabilityUsesHumanizedName() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"contractId":"acme::do_the_thing","payload":{"name":"alpha"}}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "acme::do_the_thing",
                implementationId: "external_openapi.acme.v1.do_the_thing",
                functionId: "acme::do_the_thing",
                pluginId: "external_openapi.acme",
                trustTier: "external_openapi"
            )
        )

        XCTAssertEqual(invocation.display.capabilityName, "Do The Thing")
        XCTAssertEqual(invocation.display.commandText, "alpha")
        XCTAssertEqual(CapabilityPresentation.sourceLabel(for: invocation.identity), "OpenAPI")
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
        XCTAssertEqual(CapabilityPresentation.pluginLabel(for: firstParty), "Process (First-party)")
        XCTAssertEqual(CapabilityPresentation.pluginLabel(for: mcp), "GitHub (MCP)")
    }

    func testPresentationUsesCapabilityThemeColorWhenProvided() {
        let identity = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "notifications::send",
            implementationId: "first_party.notifications.v1.send",
            functionId: "notifications::send",
            pluginId: "first_party.notifications",
            trustTier: "first_party_signed",
            themeColor: "#EC4899"
        )

        XCTAssertEqual(CapabilityPresentation.pluginLabel(for: identity), "Notifications (First-party)")
        XCTAssertEqual(identity.themeColor, "#EC4899")
    }

    func testPresentationDerivesThemeColorFromResolvedCapabilityWhenEventOmitsHint() {
        let process = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "process::run",
            implementationId: "first_party.process.v1.run",
            functionId: "process::run",
            pluginId: "first_party.process",
            trustTier: "first_party_signed"
        )
        let notification = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "notifications::send",
            implementationId: "first_party.notifications.v1.send",
            functionId: "notifications::send",
            pluginId: "first_party.notifications",
            trustTier: "first_party_signed"
        )

        XCTAssertEqual(CapabilityPresentation.themeColorHex(for: process), "#38BDF8")
        XCTAssertEqual(CapabilityPresentation.themeColorHex(for: notification), "#EC4899")
    }

    func testPresentationDerivesRunningExecuteThemeColorFromRequestedTarget() {
        let identity = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "capability::execute",
            implementationId: "first_party.capability.v1.execute",
            functionId: "capability::execute",
            pluginId: "first_party.capability",
            trustTier: "first_party_signed"
        )

        XCTAssertEqual(
            CapabilityPresentation.themeColorHex(for: identity, targetId: "process::run"),
            "#38BDF8"
        )
        XCTAssertEqual(
            CapabilityPresentation.themeColorHex(for: identity, targetId: "notifications::send"),
            "#EC4899"
        )
    }
}
