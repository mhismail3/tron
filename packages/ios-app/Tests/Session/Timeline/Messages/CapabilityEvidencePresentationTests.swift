import XCTest
@testable import TronMobile

final class CapabilityEvidencePresentationTests: XCTestCase {
    func testChipTextIsOneLineTitleAndQualifier() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"operation":"file_read","payload":{"path":"/tmp/work/README.md"}}"#,
            result: #"{"content":"hello","path":"/tmp/work/README.md"}"#,
            identity: CapabilityIdentity(modelPrimitiveName: "execute", operationName: "file_read")
        )

        let presentation = CapabilityEvidencePresentation(data: invocation)

        XCTAssertEqual(presentation.title, "File Read")
        XCTAssertEqual(presentation.qualifier, "README.md")
        XCTAssertEqual(presentation.chipText, "File Read · README.md")
        XCTAssertFalse(presentation.chipText.contains("\n"))
    }

    func testSectionsKeepTechnicalLast() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"operation":"process_run","payload":{"command":"pwd"}}"#,
            result: #"{"stdout":"/tmp/project\n"}"#,
            durationMs: 10,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                operationName: "process_run",
                traceId: "trace-process"
            )
        )

        let sections = CapabilityEvidencePresentation(data: invocation).sections

        XCTAssertEqual(sections.first?.kind, .summary)
        XCTAssertEqual(sections.last?.kind, .technical)
        XCTAssertTrue(sections.contains { $0.kind == .input })
        XCTAssertTrue(sections.contains { $0.kind == .result })
    }

    func testFailureUsesErrorSummaryBeforeTargetNoise() {
        let invocation = CapabilityInvocationData(
            id: "call_error",
            status: .error,
            arguments: #"{"operation":"file_write","payload":{"path":"/tmp/work/Foo.swift"}}"#,
            result: #"{"error":"Permission denied"}"#,
            identity: CapabilityIdentity(modelPrimitiveName: "execute", operationName: "file_write"),
            errorClassification: CapabilityErrorClassification(
                code: "permission_denied",
                category: "filesystem",
                message: "Permission denied",
                recoverable: false
            )
        )

        let presentation = CapabilityEvidencePresentation(data: invocation)

        XCTAssertEqual(presentation.title, "File Write")
        XCTAssertEqual(presentation.qualifier, "Permission denied")
        XCTAssertTrue(presentation.sections.contains { $0.kind == .error })
    }
}
