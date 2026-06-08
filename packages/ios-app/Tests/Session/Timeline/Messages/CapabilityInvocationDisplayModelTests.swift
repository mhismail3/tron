import XCTest
@testable import TronMobile

final class CapabilityInvocationDisplayModelTests: XCTestCase {
    func testExecuteUsesOperationNameAndPayloadSummary() {
        let invocation = testCapabilityInvocation(
            status: .running,
            arguments: #"{"operation":"process_run","payload":{"command":"git status --short","executionMode":"read_only"},"reason":"Check repository state."}"#,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                operationName: "process_run",
                traceId: "trace-process"
            )
        )

        XCTAssertEqual(invocation.display.primitiveTitle, "Action")
        XCTAssertEqual(invocation.display.sheetTitle, "Process Run")
        XCTAssertEqual(invocation.display.chipTitle, "Process Run")
        XCTAssertEqual(invocation.display.targetId, "process_run")
        XCTAssertEqual(invocation.display.payloadSummary, "git status --short")
        XCTAssertEqual(invocation.display.commandText, "git status --short")
        XCTAssertEqual(invocation.display.requestRows.map(\.label), ["Command", "Execution mode", "Operation", "Reason"])
    }

    func testIntentOnlyExecuteDoesNotInventCatalogTarget() {
        let invocation = testCapabilityInvocation(
            status: .generating,
            arguments: #"{"intent":"find a way to update durable state"}"#,
            identity: CapabilityIdentity(modelPrimitiveName: "execute")
        )

        XCTAssertEqual(invocation.display.sheetTitle, "Action")
        XCTAssertEqual(invocation.display.chipTitle, "Action")
        XCTAssertNil(invocation.display.targetId)
        XCTAssertEqual(invocation.display.commandText, "intent=find a way to update durable state")
        XCTAssertEqual(invocation.display.progressSteps.map(\.title), ["Request", "Run", "Finish"])
        XCTAssertEqual(invocation.display.progressSteps.map(\.state), [.current, .pending, .pending])
    }

    func testResultAndTraceRowsStayGeneric() {
        let invocation = testCapabilityInvocation(
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
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                operationName: "file_read",
                traceId: "trace-file",
                rootInvocationId: "root-file",
                themeColor: "#10B981"
            )
        )

        XCTAssertEqual(invocation.display.payloadSummary, "README.md")
        XCTAssertEqual(invocation.display.resultPreview, "hello\nworld")
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Trace", value: "trace-file", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Root invocation", value: "root-file", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Result path", value: "README.md", isTechnical: true)))
    }

    func testActionRowsExposeTraceNotExecutor() {
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"operation":"process_run","payload":{"command":"pwd"},"reason":"Confirm workspace."}"#,
            result: #"{"stdout":"/tmp/project\n"}"#,
            details: ["output": ["stdout": "/tmp/project\n"]],
            durationMs: 12,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                operationName: "process_run",
                traceId: "trace-process-1234567890"
            )
        )

        XCTAssertEqual(invocation.display.actionRows.map(\.label), ["What happened", "Why", "Trace", "Status", "Result"])
        XCTAssertTrue(invocation.display.actionRows.contains(CapabilityDisplayRow(label: "Trace", value: "trace-proces")))
        XCTAssertFalse(invocation.display.actionRows.contains { $0.label == "Executor" })
    }

    func testPresentationUsesRuntimeHintsOnly() {
        let identity = CapabilityIdentity(
            modelPrimitiveName: "execute",
            operationName: "process_run",
            traceId: "trace-hints",
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
            arguments: #"{"operation":"process_run","payload":{"command":"pwd"}}"#,
            identity: identity
        )

        XCTAssertEqual(invocation.display.capabilityName, "Shell Command")
        XCTAssertEqual(invocation.display.chipTitle, "Shell")
        XCTAssertEqual(CapabilityPresentation.symbol(for: identity), "terminal")
        XCTAssertEqual(CapabilityPresentation.themeColorHex(for: identity), "#38BDF8")
    }

    func testObservedDurationCanExceedServerDuration() {
        let started = Date(timeIntervalSince1970: 1_000)
        let completed = started.addingTimeInterval(2.4)
        let invocation = testCapabilityInvocation(
            status: .success,
            arguments: #"{"operation":"process_run","payload":{"command":"date"}}"#,
            durationMs: 80,
            startedAt: started,
            completedAt: completed,
            identity: CapabilityIdentity(
                modelPrimitiveName: "execute",
                operationName: "process_run"
            )
        )

        XCTAssertEqual(invocation.formattedDuration, "2.4s")
        XCTAssertEqual(invocation.serverFormattedDuration, "80ms")
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Server duration", value: "80ms", isTechnical: true)))
        XCTAssertTrue(invocation.display.technicalRows.contains(CapabilityDisplayRow(label: "Observed duration", value: "2.4s", isTechnical: true)))
    }
}
