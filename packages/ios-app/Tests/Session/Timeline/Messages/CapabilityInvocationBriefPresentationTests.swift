import XCTest
@testable import TronMobile

final class CapabilityInvocationBriefPresentationTests: XCTestCase {
    func testSuccessBriefingSummarizesOutcomeWithoutRawTechnicalRefs() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"operation":"module_dependency_policy_list","limit":100}"#,
            result: #"{"status":"ok","message":"Listed 0 module dependency policy record(s)."}"#,
            durationMs: 19,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                operationName: "module_dependency_policy_list",
                traceId: "019f3b2f-90e3-7d00-9cd3-a829338b0c4f"
            )
        )

        let brief = CapabilityInvocationBriefPresentation(data: invocation)

        XCTAssertEqual(brief.title, "Module Dependency Policy List")
        XCTAssertEqual(brief.tone, .success)
        XCTAssertTrue(brief.narrative.contains("completed"))
        XCTAssertTrue(brief.narrative.contains("returned"))
        XCTAssertTrue(brief.resultBody?.contains("Listed 0 module dependency policy record") == true)
        XCTAssertFalse(brief.narrative.contains("019f3b2f"))
        XCTAssertTrue(brief.evidenceRows.contains { $0.label == "Trace ref" && $0.value == "019f3b2f…0c4f" })
        XCTAssertTrue(brief.technicalRows.contains { $0.label == "Trace" && $0.value.contains("019f3b2f") })
    }

    func testPolicyFailureRedactsAuthorityIdsAtTopLevelAndGivesNextStep() {
        let invocation = CapabilityInvocationData(
            id: "call_7tRZmoApAHghiHsXyVArLvS1",
            status: .error,
            arguments: #"{"operation":"capability_binding_request_list","limit":100}"#,
            result: "authority grant 019f3b30-0be0-7802-a298-d8cda2c1c590 requires explicit kind:capability_binding_request selector for capability binding policy operations",
            durationMs: 12,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                operationName: "capability_binding_request_list",
                traceId: "019f3b2f-90e3-7d00-9cd3-a829338b0c4f"
            ),
            errorClassification: CapabilityErrorClassification(
                code: "ENGINE_POLICY_VIOLATION",
                category: "invalid_request",
                message: "authority grant 019f3b30-0be0-7802-a298-d8cda2c1c590 requires explicit kind:capability_binding_request selector for capability binding policy operations",
                recoverable: true
            )
        )

        let brief = CapabilityInvocationBriefPresentation(data: invocation)

        XCTAssertEqual(brief.tone, .attention)
        XCTAssertEqual(brief.issue?.title, "Policy blocked this request")
        XCTAssertTrue(brief.issue?.message.contains("[id]") == true)
        XCTAssertFalse(brief.issue?.message.contains("019f3b30") == true)
        XCTAssertEqual(brief.issue?.nextStep, "Retry with the explicit capability_binding_request selector.")
        XCTAssertFalse(brief.subtitle?.contains("019f3b30") == true)
        XCTAssertTrue(brief.technicalRows.contains { $0.label == "Invocation" && $0.value.contains("call_7tRZ") })
    }

    func testRawPayloadIsSeparatedFromConciseRequestRows() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"operation":"process_run","payload":{"command":"git status --short","cwd":"/tmp/work/tron","executionMode":"read_only"}}"#,
            result: #"{"stdout":"clean\n","exitCode":0}"#,
            identity: CapabilityIdentity(modelPrimitiveName: "execute", operationName: "process_run")
        )

        let brief = CapabilityInvocationBriefPresentation(data: invocation)

        XCTAssertTrue(brief.requestRows.contains { $0.label == "Command" && $0.value == "git status --short" })
        XCTAssertTrue(brief.requestRows.contains { $0.label == "Working directory" && $0.value == "tron" })
        XCTAssertTrue(brief.rawPayload?.contains("git status --short") == true)
        XCTAssertFalse(brief.factRows.contains { $0.value.contains("/tmp/work") })
    }
}
