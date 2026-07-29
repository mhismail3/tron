import XCTest
@testable import TronMobile

final class ToolInvocationBriefPresentationTests: XCTestCase {
    func testSuccessBriefingSummarizesOutcomeWithoutRawTechnicalRefs() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"includeRetired":true}"#,
            result: #"{"status":"ok","message":"Listed 0 persistent workers."}"#,
            durationMs: 19,
            identity: ToolIdentity(
                toolName: "worker_list",
                traceId: "019f3b2f-90e3-7d00-9cd3-a829338b0c4f"
            )
        )

        let brief = ToolInvocationBriefPresentation(data: invocation)

        XCTAssertEqual(brief.title, "Worker List")
        XCTAssertTrue(brief.narrative.contains("completed"))
        XCTAssertFalse(brief.narrative.contains("{"))
        XCTAssertTrue(brief.resultBody?.contains("Listed 0 persistent workers") == true)
        XCTAssertFalse(brief.narrative.contains("019f3b2f"))
        XCTAssertTrue(brief.evidenceRows.contains { $0.label == "Trace ref" && $0.value == "019f3b2f…0c4f" })
        XCTAssertTrue(brief.technicalRows.contains { $0.label == "Trace" && $0.value.contains("019f3b2f") })
    }

    func testSurfaceClassificationUsesOnlyEngineOwnedContractMetadata() {
        let workerIdentity = ToolIdentity(
            toolName: "worker_work_ledger",
            presentationHints: [
                "surfaceKind": "worker",
                "workerId": "work-ledger",
                "workerName": "Work Ledger",
                "workerVersion": "version-2",
                "runnerKind": "agent"
            ]
        )
        let coreIdentity = ToolIdentity(
            toolName: "process_run",
            presentationHints: [
                "surfaceKind": "core",
                "primitiveGroup": "host"
            ]
        )

        XCTAssertEqual(
            ToolInvocationSurface(identity: workerIdentity),
            .worker(
                .init(
                    id: "work-ledger",
                    name: "Work Ledger",
                    version: "version-2",
                    runnerKind: "agent"
                )
            )
        )
        XCTAssertEqual(
            ToolInvocationSurface(identity: workerIdentity).displayKind,
            "Agent worker"
        )
        XCTAssertEqual(
            ToolEvidencePresentation(
                data: testToolInvocation(identity: workerIdentity)
            ).title,
            "Work Ledger"
        )
        XCTAssertEqual(ToolInvocationSurface(identity: coreIdentity), .core(group: "host"))
        XCTAssertEqual(
            ToolInvocationSurface(identity: ToolIdentity(toolName: "worker_looks_like_one")),
            .unknown
        )
    }

    func testPartialLifecycleIdentityDoesNotEraseWorkerPresentationContract() {
        let started = ToolIdentity(
            toolName: "worker_general_delegate",
            traceId: "trace-start",
            presentationHints: [
                "surfaceKind": "worker",
                "workerId": "general-delegate",
                "workerName": "General Delegate",
                "runnerKind": "agent"
            ]
        )
        let completed = ToolIdentity(
            toolName: "worker_general_delegate",
            rootInvocationId: "root-completed"
        )

        let merged = started.merging(completed)

        XCTAssertEqual(merged.traceId, "trace-start")
        XCTAssertEqual(merged.rootInvocationId, "root-completed")
        XCTAssertEqual(ToolInvocationSurface(identity: merged).workerName, "General Delegate")
        XCTAssertTrue(ToolInvocationSurface(identity: merged).isAgentWorker)
    }

    func testStructuredWorkerResultPreservesTypedNestedValues() throws {
        let invocation = testToolInvocation(
            arguments: #"{"action":"list_goals","status":"all"}"#,
            result: #"""
            {
              "action": "list_goals",
              "goals": [
                {
                  "id": "goal-1",
                  "title": "Restore workers",
                  "active": true,
                  "completedAt": null
                }
              ],
              "count": 1
            }
            """#
        )

        let request = try XCTUnwrap(ToolStructuredDocument.request(from: invocation))
        let result = try XCTUnwrap(ToolStructuredDocument.result(from: invocation))

        XCTAssertEqual(
            request.root,
            .object([
                .init(key: "action", value: .string("list_goals")),
                .init(key: "status", value: .string("all"))
            ])
        )
        XCTAssertEqual(
            result.root,
            .object([
                .init(key: "action", value: .string("list_goals")),
                .init(key: "count", value: .number("1")),
                .init(
                    key: "goals",
                    value: .array([
                        .object([
                            .init(key: "active", value: .boolean(true)),
                            .init(key: "completedAt", value: .null),
                            .init(key: "id", value: .string("goal-1")),
                            .init(key: "title", value: .string("Restore workers"))
                        ])
                    ])
                )
            ])
        )
        XCTAssertNil(ToolStructuredDocument.result(content: "plain result", details: nil))
    }

    func testSchemaFailureRedactsOpaqueIdsAtTopLevelAndGivesNextStep() {
        let invocation = ToolInvocationData(
            id: "call_7tRZmoApAHghiHsXyVArLvS1",
            status: .error,
            arguments: #"{"workerId":"recent-research","input":{}}"#,
            result: "worker input schema rejected trace 019f3b30-0be0-7802-a298-d8cda2c1c590 because required property topic is missing",
            durationMs: 12,
            identity: ToolIdentity(
                toolName: "worker_invoke",
                traceId: "019f3b2f-90e3-7d00-9cd3-a829338b0c4f"
            ),
            errorClassification: ToolErrorClassification(
                code: "ENGINE_SCHEMA_VIOLATION",
                category: "invalid_request",
                message: "worker input schema rejected trace 019f3b30-0be0-7802-a298-d8cda2c1c590 because required property topic is missing",
                recoverable: true
            )
        )

        let brief = ToolInvocationBriefPresentation(data: invocation)

        XCTAssertEqual(brief.issue?.title, "Request shape needs correction")
        XCTAssertTrue(brief.issue?.message.contains("[id]") == true)
        XCTAssertFalse(brief.issue?.message.contains("019f3b30") == true)
        XCTAssertEqual(brief.issue?.nextStep, "This is recoverable after correcting the request.")
        XCTAssertFalse(brief.subtitle?.contains("019f3b30") == true)
        XCTAssertTrue(brief.technicalRows.contains { $0.label == "Invocation" && $0.value.contains("call_7tRZ") })
    }

    func testCurrentPolicyFailureKeepsPolicyClassification() {
        let invocation = ToolInvocationData(
            id: "call_policy_failure",
            status: .error,
            arguments: "{}",
            result: "policy violation: mutating invocation requires an idempotency key",
            identity: ToolIdentity(
                toolName: "worker_disable",
            ),
            errorClassification: ToolErrorClassification(
                code: "ENGINE_POLICY_VIOLATION",
                category: "policy",
                message: "policy violation: mutating invocation requires an idempotency key",
                recoverable: true
            )
        )

        let brief = ToolInvocationBriefPresentation(data: invocation)

        XCTAssertEqual(brief.issue?.title, "Policy blocked this request")
        XCTAssertEqual(brief.issue?.nextStep, "This is recoverable after correcting the request.")
    }

    func testRawPayloadIsSeparatedFromConciseRequestRows() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"command":["git","status","--short"],"cwd":"/tmp/work/tron"}"#,
            result: #"{"stdout":"clean\n","exitCode":0}"#,
            identity: ToolIdentity(toolName: "process_run")
        )

        let brief = ToolInvocationBriefPresentation(data: invocation)

        XCTAssertTrue(brief.requestRows.contains { $0.label == "Command" && $0.value == "git status --short" })
        XCTAssertTrue(brief.requestRows.contains { $0.label == "Working directory" && $0.value == "tron" })
        XCTAssertTrue(brief.rawPayload?.contains(#""command""#) == true)
        XCTAssertTrue(brief.rawPayload?.contains(#""git""#) == true)
        XCTAssertFalse(brief.factRows.contains { $0.value.contains("/tmp/work") })
    }

    func testBackgroundWorkerHandoffIsNotPresentedAsCompletedWork() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"question":"What is new today?"}"#,
            result: #"""
            {
              "kind": "worker_invocation_receipt",
              "status": "running",
              "mode": "background",
              "invocationId": "worker_run_019f9505-bd6d-7190-a683-698b1ce06b3b",
              "workerId": "research-coordinator",
              "message": "The durable worker run is continuing in the background."
            }
            """#,
            durationMs: 10_000,
            identity: ToolIdentity(
                toolName: "worker_research_coordinator",
                presentationHints: [
                    "surfaceKind": "worker",
                    "workerId": "research-coordinator",
                    "workerName": "Research Coordinator",
                    "runnerKind": "agent"
                ]
            )
        )

        let brief = ToolInvocationBriefPresentation(data: invocation)

        XCTAssertTrue(brief.isBackgroundHandoff)
        XCTAssertEqual(
            brief.backgroundInvocationId,
            "worker_run_019f9505-bd6d-7190-a683-698b1ce06b3b"
        )
        XCTAssertTrue(brief.headline.contains("continuing in the background"))
        XCTAssertTrue(brief.narrative.contains("Session Context"))
        XCTAssertTrue(brief.factRows.contains { $0.label == "Status" && $0.value == "Background" })
        XCTAssertTrue(brief.factRows.contains { $0.label == "Foreground wait" && $0.value == "10.0s" })
        XCTAssertFalse(brief.narrative.contains("completed"))
    }

    func testPendingDurableWaitPresentsSuccessfulAutoResumeRegistration() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"invocationIds":["worker-one","worker-two"],"mode":"all"}"#,
            result: #"""
            {
              "waitId": "wait-one",
              "mode": "all",
              "invocationIds": ["worker-one", "worker-two"],
              "status": "pending",
              "deliveryIds": []
            }
            """#,
            identity: ToolIdentity(toolName: "agent_wait_for_workers")
        )

        let brief = ToolInvocationBriefPresentation(data: invocation)

        XCTAssertEqual(brief.title, "Auto-resume registered")
        XCTAssertEqual(brief.durableWait?.status, "pending")
        XCTAssertEqual(brief.durableWait?.workerCount, 2)
        XCTAssertTrue(brief.narrative.contains("resume automatically"))
        XCTAssertFalse(brief.narrative.contains("workers completed"))
    }

    func testAlreadySatisfiedDurableWaitIsNotShownAsActivelyWaiting() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"invocationIds":["worker-one"],"mode":"any"}"#,
            result: #"""
            {
              "waitId": "wait-one",
              "mode": "any",
              "invocationIds": ["worker-one"],
              "status": "satisfied",
              "deliveryIds": ["delivery-one"]
            }
            """#,
            identity: ToolIdentity(toolName: "worker_kernel::agent_wait_for_workers")
        )

        let brief = ToolInvocationBriefPresentation(data: invocation)

        XCTAssertEqual(brief.title, "Worker wait satisfied")
        XCTAssertEqual(brief.durableWait?.isPending, false)
        XCTAssertTrue(brief.narrative.contains("already satisfied"))
    }

    func testActivityLogSplitsBoundsAndDeduplicatesUpdates() {
        var log: [String] = []
        log = ToolActivityLog.appending("Started Search\nFinished Search", to: log)
        log = ToolActivityLog.appending("Finished Search", to: log)

        XCTAssertEqual(log, ["Started Search", "Finished Search"])

        for index in 0..<80 {
            log = ToolActivityLog.appending("step \(index)", to: log)
        }
        XCTAssertEqual(log.count, 64)
        XCTAssertEqual(log.last, "step 79")
    }
}
