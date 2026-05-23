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
        XCTAssertEqual(invocation.display.chipTitle, "Inspect")
        XCTAssertEqual(invocation.display.capabilityName, "Run Command")
        XCTAssertEqual(invocation.display.commandText, "Run Command")
        XCTAssertEqual(invocation.display.targetId, "process::run")
    }

    func testInspectChipTitleNamesPrimitiveBeforeTarget() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"contractId":"filesystem::read_file"}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "inspect",
                contractId: "filesystem::read_file",
                implementationId: "first_party.filesystem.v1.read_file",
                functionId: "filesystem::read_file"
            )
        )

        XCTAssertEqual(invocation.display.chipTitle, "Inspect")
        XCTAssertEqual(invocation.display.commandText, "Read File")
        XCTAssertEqual(invocation.display.capabilityName, "Read File")
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
        XCTAssertEqual(invocation.display.chipTitle, "Run Command")
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

    func testExecuteDisplaysTargetArgumentsAndExecutionPath() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"target":"process::run","intent":"Run a safe read-only process command.","arguments":{"command":"pwd && sed -n '1,3p' README.md","executionMode":"read_only"},"reason":"User requested an exact read-only process command."}"#,
            result: #"{"durationMs":10,"exitCode":0,"outputTruncated":false,"stderr":"","stdout":"/tmp/worktree\nREADME\n","timedOut":false}"#,
            details: [
                "status": "ok",
                "catalogRevision": 389,
                "childInvocations": ["019e4be0-28d5-71a1-a8c9-c70640ecd6b4"],
                "bindingDecision": [
                    "selectionPolicy": "first_party_healthy",
                    "selectedImplementation": "first_party.process.v1.run"
                ],
                "correctedRequest": [
                    "target": ["capabilityId": "process::run"],
                    "arguments": [
                        "command": "pwd && sed -n '1,3p' README.md",
                        "executionMode": "read_only"
                    ]
                ],
                "correctionConfidence": 1.0,
                "correctionsApplied": [],
                "orchestration": [
                    "phaseDetails": [
                        "resolveMode": "explicit_target",
                        "preparedRequest": [
                            "hasPayload": true,
                            "hasInspectionHandle": false
                        ],
                        "selectedTarget": [
                            "catalogRevision": 389,
                            "contractId": "process::run",
                            "effectClass": "ExternalSideEffect",
                            "functionId": "process::run",
                            "implementationId": "first_party.process.v1.run",
                            "riskLevel": "High",
                            "schemaDigest": "sha256:process-schema"
                        ]
                    ]
                ],
                "output": [
                    "durationMs": 10,
                    "exitCode": 0,
                    "outputTruncated": false,
                    "stderr": "",
                    "stdout": "/tmp/worktree\nREADME\n",
                    "timedOut": false
                ]
            ],
            durationMs: 192,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "process::run",
                implementationId: "first_party.process.v1.run",
                functionId: "process::run",
                pluginId: "first_party.process",
                workerId: "process",
                schemaDigest: "sha256:process-schema",
                catalogRevision: 389,
                trustTier: "first_party_signed",
                riskLevel: "High",
                effectClass: "ExternalSideEffect",
                traceId: "trace-process",
                rootInvocationId: "root-process",
                bindingDecisionId: "binding-process"
            )
        )

        XCTAssertEqual(invocation.display.commandText, "pwd && sed -n '1,3p' README.md")
        XCTAssertEqual(
            invocation.display.requestRows.map(\.label),
            ["Command", "Execution mode", "Intent", "Reason"]
        )
        XCTAssertFalse(invocation.display.requestRows.contains { $0.label == "Payload" })
        XCTAssertEqual(invocation.display.executionGroups.map(\.title), ["Resolution", "Preparation", "Run"])
        XCTAssertTrue(invocation.display.executionGroups[0].rows.contains(CapabilityDisplayRow(label: "Mode", value: "Explicit Target")))
        XCTAssertTrue(invocation.display.executionGroups[0].rows.contains(CapabilityDisplayRow(label: "Target", value: "process::run", isTechnical: true)))
        XCTAssertTrue(invocation.display.executionGroups[0].rows.contains(CapabilityDisplayRow(label: "Selection", value: "First Party Healthy")))
        XCTAssertTrue(invocation.display.executionGroups[1].rows.contains(CapabilityDisplayRow(label: "Capability risk", value: "High")))
        XCTAssertTrue(invocation.display.executionGroups[1].rows.contains(CapabilityDisplayRow(label: "Effect class", value: "External Side Effect")))
        XCTAssertTrue(invocation.display.executionGroups[1].rows.contains(CapabilityDisplayRow(label: "Approval", value: "Not required")))
        XCTAssertTrue(invocation.display.executionGroups[1].rows.contains(CapabilityDisplayRow(label: "Corrections", value: "None")))
        XCTAssertTrue(invocation.display.executionGroups[2].rows.contains(CapabilityDisplayRow(label: "Status", value: "Completed")))
        XCTAssertFalse(invocation.display.executionGroups[2].rows.contains { $0.label == "Exit code" })
        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Exit code", value: "0")))
        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Timed out", value: "No")))
        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Output truncated", value: "No")))
        XCTAssertEqual(invocation.display.resultPreview, "/tmp/worktree\nREADME")
    }

    func testExecuteDisplaysApprovalReplayAsProvenanceNotFreshApproval() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"target":"process::run","intent":"Replay a materialized process command.","arguments":{"command":"printf hi > replay.txt","executionMode":"sandbox_materialized","expectedOutputs":[{"path":"replay.txt"}]},"idempotencyKey":"manual-replay"}"#,
            details: [
                "approvalRequired": false,
                "approvalCreated": false,
                "approvalExecuted": false,
                "approvalReplayed": true,
                "approvalReplay": [
                    "approvalId": "approval-original",
                    "status": "executed",
                    "functionId": "process::run",
                    "childInvocationIds": ["child-original"]
                ],
                "childInvocationCreated": false,
                "childInvocations": ["child-original"]
            ],
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "process::run",
                implementationId: "first_party.process.v1.run",
                functionId: "process::run"
            )
        )

        let preparation = invocation.display.executionGroups.first { $0.title == "Preparation" }
        XCTAssertTrue(
            preparation?.rows.contains(CapabilityDisplayRow(label: "Approval", value: "Replayed previous approval")) == true
        )
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

    func testPresentationUsesServerOwnedHintsWhenProvided() {
        let identity = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "process::run",
            implementationId: "first_party.process.v1.run",
            functionId: "process::run",
            pluginId: "first_party.process",
            trustTier: "first_party_signed",
            presentationHints: [
                "displayName": "Shell Command",
                "chipTitle": "Shell",
                "icon": "terminal",
                "themeColor": "#38BDF8"
            ]
        )
        let invocation = CapabilityInvocationData(
            id: "cap-1",
            status: .success,
            arguments: #"{"intent":"run a command","target":"process::run","arguments":{"command":"pwd","executionMode":"read_only"}}"#,
            identity: identity
        )

        XCTAssertEqual(invocation.display.capabilityName, "Shell Command")
        XCTAssertEqual(invocation.display.chipTitle, "Shell")
        XCTAssertEqual(CapabilityPresentation.symbol(for: identity), "terminal")
        XCTAssertEqual(CapabilityPresentation.themeColorHex(for: identity), "#38BDF8")
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
