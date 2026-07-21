import Foundation
@testable import TronMobile

func testToolIdentity(
    toolName: String = "process_run",
    traceId: String? = "trace-test",
    rootInvocationId: String? = "invocation-test",
    themeColor: String? = nil,
    presentationHints: [String: AnyCodable]? = nil
) -> ToolIdentity {
    ToolIdentity(
        toolName: toolName,
        traceId: traceId,
        rootInvocationId: rootInvocationId,
        themeColor: themeColor,
        presentationHints: presentationHints
    )
}

func testToolInvocation(
    id: String = "call_test",
    status: ToolInvocationStatus = .success,
    arguments: String = "{}",
    result: String? = nil,
    details: [String: AnyCodable]? = nil,
    durationMs: Int? = nil,
    generatedAt: Date? = nil,
    startedAt: Date? = nil,
    completedAt: Date? = nil,
    identity: ToolIdentity = testToolIdentity()
) -> ToolInvocationData {
    ToolInvocationData(
        id: id,
        status: status,
        arguments: arguments,
        result: result,
        details: details,
        durationMs: durationMs,
        generatedAt: generatedAt,
        startedAt: startedAt,
        completedAt: completedAt,
        identity: identity
    )
}

func testToolResult(
    id: String = "call_test",
    content: String = "ok",
    isError: Bool = false,
    identity: ToolIdentity = testToolIdentity()
) -> ToolInvocationResultData {
    ToolInvocationResultData(
        id: id,
        content: content,
        isError: isError,
        identity: identity,
        arguments: nil,
        durationMs: nil,
        details: nil
    )
}
