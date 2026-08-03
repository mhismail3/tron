import XCTest
@testable import TronMobile

final class ToolEvidencePresentationTests: XCTestCase {
    func testChipTextIsOneLineTitleAndQualifier() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"path":"/tmp/work/README.md"}"#,
            result: #"{"content":"hello","path":"/tmp/work/README.md"}"#,
            identity: ToolIdentity(toolName: "filesystem_read")
        )

        let presentation = ToolEvidencePresentation(data: invocation)

        XCTAssertEqual(presentation.title, "Filesystem Read")
        XCTAssertEqual(presentation.qualifier, "README.md")
        XCTAssertEqual(presentation.chipText, "Filesystem Read · README.md")
        XCTAssertFalse(presentation.chipText.contains("\n"))
    }

    func testSectionsKeepTechnicalLast() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"command":["pwd"]}"#,
            result: #"{"stdout":"/tmp/project\n"}"#,
            durationMs: 10,
            identity: ToolIdentity(
                toolName: "process_run",
                traceId: "trace-process"
            )
        )

        let sections = ToolEvidencePresentation(data: invocation).sections

        XCTAssertEqual(sections.first?.kind, .summary)
        XCTAssertEqual(sections.last?.kind, .technical)
        XCTAssertTrue(sections.contains { $0.kind == .input })
        XCTAssertTrue(sections.contains { $0.kind == .result })
    }

    func testFailureUsesErrorSummaryBeforeTargetNoise() {
        let invocation = ToolInvocationData(
            id: "call_error",
            status: .error,
            arguments: #"{"path":"/tmp/work/Foo.swift"}"#,
            result: #"{"error":"Permission denied"}"#,
            identity: ToolIdentity(toolName: "filesystem_write"),
            errorClassification: ToolErrorClassification(
                code: "permission_denied",
                category: "filesystem",
                message: "Permission denied",
                recoverable: false
            )
        )

        let presentation = ToolEvidencePresentation(data: invocation)

        XCTAssertEqual(presentation.title, "Filesystem Write")
        XCTAssertEqual(presentation.qualifier, "Permission denied")
        XCTAssertTrue(presentation.sections.contains { $0.kind == .error })
    }
}
