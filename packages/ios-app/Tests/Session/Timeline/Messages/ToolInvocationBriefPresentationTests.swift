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
        XCTAssertTrue(brief.narrative.contains("returned"))
        XCTAssertTrue(brief.resultBody?.contains("Listed 0 persistent workers") == true)
        XCTAssertFalse(brief.narrative.contains("019f3b2f"))
        XCTAssertTrue(brief.evidenceRows.contains { $0.label == "Trace ref" && $0.value == "019f3b2f…0c4f" })
        XCTAssertTrue(brief.technicalRows.contains { $0.label == "Trace" && $0.value.contains("019f3b2f") })
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
}
