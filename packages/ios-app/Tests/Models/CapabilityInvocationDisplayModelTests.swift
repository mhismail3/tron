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
                implementationId: "runtime.capability.v1.search",
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
                implementationId: "runtime.capability.v1.inspect",
                functionId: "capability::inspect"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Inspect")
        XCTAssertEqual(invocation.display.sheetTitle, "Inspect")
        XCTAssertEqual(invocation.display.chipTitle, "Inspect")
        XCTAssertEqual(invocation.display.capabilityName, "Run")
        XCTAssertEqual(invocation.display.commandText, "Run")
        XCTAssertEqual(invocation.display.targetId, "process::run")
    }

    func testInspectChipTitleNamesPrimitiveBeforeTarget() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"contractId":"filesystem::read_file"}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "inspect",
                contractId: "filesystem::read_file",
                implementationId: "runtime.filesystem.v1.read_file",
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
                implementationId: "runtime.capability.v1.execute",
                functionId: "capability::execute"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Action")
        XCTAssertEqual(invocation.display.sheetTitle, "Run")
        XCTAssertEqual(invocation.display.chipTitle, "Run")
        XCTAssertEqual(invocation.display.targetId, "process::run")
        XCTAssertEqual(invocation.display.payloadSummary, "date +%s")
        XCTAssertEqual(invocation.display.capabilityName, "Run")
        XCTAssertEqual(invocation.display.commandText, "date +%s")
        XCTAssertEqual(invocation.display.requestRows.first?.label, "Command")
        XCTAssertEqual(invocation.display.requestRows.first?.value, "date +%s")
        XCTAssertEqual(invocation.display.progressSteps.map(\.title), ["Choose", "Prepare", "Run", "Finish"])
        XCTAssertEqual(invocation.display.progressSteps.map(\.state), [.completed, .completed, .attention, .attention])
        XCTAssertFalse(invocation.display.commandText.contains("runtime.capability.v1.execute"))
    }

    func testIntentOnlyExecuteDoesNotExposeWrapperImplementationAsTarget() {
        let invocation = testCapabilityInvocation(
            status: .error,
            arguments: #"{"intent":"calibrate warp-core coolant harmonics for a starship drive","reason":"Attempt to resolve the requested capability without inventing a target."}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "capability::execute",
                implementationId: "runtime.capability.v1.execute",
                functionId: "capability::execute",
                pluginId: "runtime.capability",
                trustTier: "runtime"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Action")
        XCTAssertEqual(invocation.display.sheetTitle, "Action")
        XCTAssertEqual(invocation.display.chipTitle, "Action")
        XCTAssertNil(invocation.display.targetId)
        XCTAssertEqual(invocation.display.capabilityName, "Action")
        XCTAssertEqual(invocation.display.commandText, "Preparing action")
        XCTAssertFalse(invocation.display.chipTitle.contains("first_party"))
        XCTAssertFalse(invocation.display.commandText.contains("first_party"))
    }

    func testExecuteChipDisplaysGenericPathPayloads() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"contractId":"filesystem::list_dir","payload":{"path":"/Users/moose/Downloads/projects/testspace/runtime/current","showHidden":false},"mode":"invoke","reason":"Smoke-test list_dir."}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "capability::execute",
                implementationId: "runtime.capability.v1.execute",
                functionId: "capability::execute"
            )
        )

        XCTAssertEqual(invocation.display.commandText, "current")
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
                implementationId: "runtime.filesystem.v1.find",
                functionId: "filesystem::find",
                pluginId: "runtime.filesystem",
                trustTier: "runtime"
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
                implementationId: "runtime.process.v1.run",
                functionId: "process::run",
                pluginId: "runtime.process",
                workerId: "process"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Action")
        XCTAssertEqual(invocation.display.targetId, "process::run")
        XCTAssertEqual(invocation.display.capabilityName, "Run")
        XCTAssertEqual(invocation.display.commandText, "pwd")
    }

    func testExecuteDefaultDetailsProjectsActionSummaryAndKeepRuntimeRaw() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"target":"process::run","intent":"Check repository state.","arguments":{"command":"git status --short","executionMode":"read_only"},"reason":"User asked for current repository state."}"#,
            result: #"{"exitCode":0,"stdout":"clean\n","stderr":"","timedOut":false,"outputTruncated":false}"#,
            details: [
                "status": "ok",
                "bindingDecision": [
                    "selectionPolicy": "runtime_ready",
                    "selectedImplementation": "runtime.process.v1.run"
                ],
                "orchestration": [
                    "phaseDetails": [
                        "resolveMode": "explicit_target",
                        "selectedTarget": [
                            "contractId": "process::run",
                            "implementationId": "runtime.process.v1.run",
                            "schemaDigest": "sha256:process"
                        ]
                    ]
                ],
                "output": [
                    "exitCode": 0,
                    "stdout": "clean\n",
                    "timedOut": false,
                    "outputTruncated": false
                ]
            ],
            durationMs: 86,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "process::run",
                implementationId: "runtime.process.v1.run",
                functionId: "process::run",
                pluginId: "runtime.process",
                workerId: "process-worker",
                schemaDigest: "sha256:process",
                trustTier: "runtime",
                riskLevel: "low",
                effectClass: "read",
                traceId: "trace-process",
                bindingDecisionId: "binding-process"
            )
        )

        XCTAssertEqual(
            invocation.display.actionRows.map(\.label),
            ["What happened", "Why", "Executor", "Status", "Result"]
        )
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "What happened", value: "Run")))
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "Why", value: "User asked for current repository state.")))
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "Executor", value: "Process Worker")))
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "Status", value: "Completed · 86ms")))
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "Result", value: "clean")))

        let defaultText = invocation.display.actionRows.map(\.value).joined(separator: " ")
        XCTAssertFalse(defaultText.contains("schema"))
        XCTAssertFalse(defaultText.contains("trace-process"))
        XCTAssertFalse(defaultText.contains("binding-process"))
        XCTAssertFalse(defaultText.contains("first_party"))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Schema", value: "sha256:process", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Trace", value: "trace-process", isTechnical: true)))
        XCTAssertNotNil(invocation.display.prettyArguments)
        XCTAssertNotNil(invocation.display.prettyResult)
    }

    func testExecuteDisplaysTargetArgumentsAndExecutionPath() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"target":"process::run","intent":"Run a safe read-only process command.","arguments":{"command":"pwd && sed -n '1,3p' README.md","executionMode":"read_only"},"reason":"User requested an exact read-only process command."}"#,
            result: #"{"durationMs":10,"exitCode":0,"outputTruncated":false,"stderr":"","stdout":"/tmp/project\nREADME\n","timedOut":false}"#,
            details: [
                "status": "ok",
                "catalogRevision": 389,
                "childInvocations": ["019e4be0-28d5-71a1-a8c9-c70640ecd6b4"],
                "bindingDecision": [
                    "selectionPolicy": "runtime_ready",
                    "selectedImplementation": "runtime.process.v1.run"
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
                            "implementationId": "runtime.process.v1.run",
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
                    "stdout": "/tmp/project\nREADME\n",
                    "timedOut": false
                ]
            ],
            durationMs: 192,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "process::run",
                implementationId: "runtime.process.v1.run",
                functionId: "process::run",
                pluginId: "runtime.process",
                workerId: "process",
                schemaDigest: "sha256:process-schema",
                catalogRevision: 389,
                trustTier: "runtime",
                riskLevel: "High",
                effectClass: "ExternalSideEffect",
                traceId: "trace-process",
                rootInvocationId: "root-process",
                bindingDecisionId: "binding-process"
            )
        )

        XCTAssertEqual(invocation.display.commandText, "pwd && sed -n '1,3p' README.md")
        XCTAssertEqual(invocation.display.sheetTitle, "Run")
        XCTAssertEqual(invocation.display.progressSteps.map(\.title), ["Choose", "Prepare", "Run", "Finish"])
        XCTAssertEqual(invocation.display.progressSteps.map(\.state), [.completed, .completed, .completed, .completed])
        XCTAssertEqual(invocation.display.progressSteps[0].detail, "Run selected")
        XCTAssertEqual(
            invocation.display.requestRows.map(\.label),
            ["Command", "Execution mode", "Intent", "Reason"]
        )
        XCTAssertFalse(invocation.display.requestRows.contains { $0.label == "Payload" })
        XCTAssertEqual(invocation.display.executionGroups.map(\.title), ["Resolution", "Preparation", "Run"])
        XCTAssertTrue(invocation.display.executionGroups[0].rows.contains(CapabilityDisplayRow(label: "Mode", value: "Explicit Target")))
        XCTAssertTrue(invocation.display.executionGroups[0].rows.contains(CapabilityDisplayRow(label: "Target", value: "process::run", isTechnical: true)))
        XCTAssertTrue(invocation.display.executionGroups[0].rows.contains(CapabilityDisplayRow(label: "Selection", value: "Runtime Ready")))
        XCTAssertTrue(invocation.display.executionGroups[1].rows.contains(CapabilityDisplayRow(label: "Capability risk", value: "High")))
        XCTAssertTrue(invocation.display.executionGroups[1].rows.contains(CapabilityDisplayRow(label: "Effect class", value: "External Side Effect")))
        XCTAssertTrue(invocation.display.executionGroups[1].rows.contains(CapabilityDisplayRow(label: "Corrections", value: "None")))
        XCTAssertFalse(invocation.display.executionGroups[1].rows.contains { $0.label == "Approval" })
        XCTAssertTrue(invocation.display.executionGroups[2].rows.contains(CapabilityDisplayRow(label: "Status", value: "Completed")))
        XCTAssertFalse(invocation.display.executionGroups[2].rows.contains { $0.label == "Exit code" })
        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Exit code", value: "0")))
        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Timed out", value: "No")))
        XCTAssertTrue(invocation.display.resultRows.contains(CapabilityDisplayRow(label: "Output truncated", value: "No")))
        XCTAssertEqual(invocation.display.resultPreview, "/tmp/project\nREADME")
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
                implementationId: "runtime.process.v1.run",
                functionId: "process::run",
                pluginId: "runtime.process",
                trustTier: "runtime"
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
        XCTAssertEqual(CapabilityPresentation.sourceLabel(for: invocation.identity), "Acme")
    }

    func testPresentationUsesGenericRuntimeSourceLabels() {
        let firstParty = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "process::run",
            implementationId: "runtime.process.v1.run",
            functionId: "process::run",
            pluginId: "runtime.process",
            trustTier: "runtime"
        )
        let mcp = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "github::search_issues",
            implementationId: "mcp.github.search_issues",
            functionId: "github::search_issues",
            pluginId: "external_mcp.github",
            trustTier: "external_mcp"
        )

        XCTAssertEqual(CapabilityPresentation.sourceLabel(for: firstParty), "Process")
        XCTAssertEqual(CapabilityPresentation.sourceLabel(for: mcp), "Github")
        XCTAssertEqual(CapabilityPresentation.pluginLabel(for: firstParty), "Process")
        XCTAssertEqual(CapabilityPresentation.pluginLabel(for: mcp), "Github")
    }

    func testPresentationUsesCapabilityThemeColorWhenProvided() {
        let identity = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "alerts::send",
            implementationId: "runtime.alerts.v1.send",
            functionId: "alerts::send",
            pluginId: "runtime.alerts",
            trustTier: "runtime",
            themeColor: "#EC4899"
        )

        XCTAssertEqual(CapabilityPresentation.pluginLabel(for: identity), "Alerts")
        XCTAssertEqual(identity.themeColor, "#EC4899")
    }

    func testPresentationUsesServerOwnedHintsWhenProvided() {
        let identity = CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: "process::run",
            implementationId: "runtime.process.v1.run",
            functionId: "process::run",
            pluginId: "runtime.process",
            trustTier: "runtime",
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

    func testExecuteWithoutTargetShowsResolutionAsCurrentProgressStep() {
        let invocation = testCapabilityInvocation(
            status: .running,
            arguments: #"{"intent":"find a capability that can safely update a file"}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                contractId: "capability::execute",
                implementationId: "runtime.capability.v1.execute",
                functionId: "capability::execute",
                pluginId: "runtime.capability",
                trustTier: "runtime"
            )
        )

        XCTAssertEqual(invocation.display.sheetTitle, "Action")
        XCTAssertEqual(invocation.display.progressSteps.map(\.title), ["Choose", "Prepare", "Run", "Finish"])
        XCTAssertEqual(invocation.display.progressSteps.map(\.state), [.current, .pending, .pending, .pending])
        XCTAssertEqual(invocation.display.progressSteps[0].detail, "Selecting runtime target")
    }
}
