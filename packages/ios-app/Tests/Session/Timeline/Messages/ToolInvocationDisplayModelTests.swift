import XCTest
@testable import TronMobile

final class ToolInvocationDisplayModelTests: XCTestCase {
    func testDirectToolUsesPayloadSummary() {
        let invocation = testToolInvocation(
            status: .running,
            arguments: #"{"command":["git","status","--short"],"executionMode":"read_only","reason":"Check repository state."}"#,
            identity: ToolIdentity(
                toolName: "process_run",
                traceId: "trace-process"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Process Run")
        XCTAssertEqual(invocation.display.sheetTitle, "Process Run")
        XCTAssertEqual(invocation.display.chipTitle, "Process Run")
        XCTAssertNil(invocation.display.targetId)
        XCTAssertEqual(invocation.display.payloadSummary, "git status --short")
        XCTAssertEqual(invocation.display.commandText, "git status --short")
        XCTAssertEqual(invocation.display.requestRows.map(\.label), ["Command", "Execution mode", "Reason"])
    }

    func testIntentOnlyDirectToolDoesNotInventTarget() {
        let invocation = testToolInvocation(
            status: .generating,
            arguments: #"{"intent":"find a way to update durable state"}"#,
            identity: ToolIdentity(toolName: "process_run")
        )

        XCTAssertEqual(invocation.display.sheetTitle, "Process Run")
        XCTAssertEqual(invocation.display.chipTitle, "Process Run")
        XCTAssertNil(invocation.display.targetId)
        XCTAssertEqual(invocation.display.commandText, "intent=find a way to update durable state")
        XCTAssertEqual(invocation.display.progressSteps.map(\.title), ["Request", "Run", "Finish"])
        XCTAssertEqual(invocation.display.progressSteps.map(\.state), [.current, .pending, .pending])
    }

    func testResultAndTraceRowsStayGeneric() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"operation":"file_read","payload":{"path":"/tmp/work/README.md"}}"#,
            result: #"{"content":"hello\nworld","path":"/tmp/work/README.md"}"#,
            details: [
                "status": "ok",
                "output": [
                    "content": "hello\nworld",
                    "path": "/tmp/work/README.md"
                ]
            ],
            durationMs: 86,
            identity: ToolIdentity(
                toolName: "process_run",
                traceId: "trace-file",
                rootInvocationId: "root-file",
                themeColor: "#10B981"
            )
        )

        XCTAssertEqual(invocation.display.payloadSummary, "README.md")
        XCTAssertEqual(invocation.display.resultPreview, "hello\nworld")
        XCTAssertTrue(invocation.display.technicalRows.contains(ToolDisplayRow(label: "Trace", value: "trace-file", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(ToolDisplayRow(label: "Root invocation", value: "root-file", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(ToolDisplayRow(label: "Result path", value: "README.md", isTechnical: true)))
    }

    func testActionRowsExposeTraceNotExecutor() {
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"operation":"process_run","payload":{"command":"pwd"},"reason":"Confirm workspace."}"#,
            result: #"{"stdout":"/tmp/project\n"}"#,
            details: ["output": ["stdout": "/tmp/project\n"]],
            durationMs: 12,
            identity: ToolIdentity(
                toolName: "process_run",
                traceId: "trace-process-1234567890"
            )
        )

        XCTAssertEqual(invocation.display.actionRows.map(\.label), ["What happened", "Why", "Trace", "Status", "Result"])
        XCTAssertTrue(invocation.display.actionRows.contains(ToolDisplayRow(label: "Trace", value: "trace-proces")))
        XCTAssertFalse(invocation.display.actionRows.contains { $0.label == "Executor" })
    }

    func testPresentationUsesRuntimeHintsOnly() {
        let identity = ToolIdentity(
            toolName: "process_run",
            traceId: "trace-hints",
            presentationHints: [
                "displayName": "Shell Command",
                "chipTitle": "Shell",
                "icon": "terminal",
                "themeColor": "#38BDF8"
            ]
        )
        let invocation = ToolInvocationData(
            id: "cap-1",
            status: .success,
            arguments: #"{"operation":"process_run","payload":{"command":"pwd"}}"#,
            identity: identity
        )

        XCTAssertEqual(invocation.display.toolName, "Shell Command")
        XCTAssertEqual(invocation.display.chipTitle, "Shell")
        XCTAssertEqual(ToolPresentation.symbol(for: identity), "terminal")
        XCTAssertEqual(ToolPresentation.themeColorHex(for: identity), "#38BDF8")
    }

    func testObservedDurationCanExceedServerDuration() {
        let started = Date(timeIntervalSince1970: 1_000)
        let completed = started.addingTimeInterval(2.4)
        let invocation = testToolInvocation(
            status: .success,
            arguments: #"{"operation":"process_run","payload":{"command":"date"}}"#,
            durationMs: 80,
            startedAt: started,
            completedAt: completed,
            identity: ToolIdentity(
                toolName: "process_run",
            )
        )

        XCTAssertEqual(invocation.formattedDuration, "2.4s")
        XCTAssertEqual(invocation.serverFormattedDuration, "80ms")
        XCTAssertTrue(invocation.display.technicalRows.contains(ToolDisplayRow(label: "Server duration", value: "80ms", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(ToolDisplayRow(label: "Observed duration", value: "2.4s", isTechnical: true)))
    }
}
