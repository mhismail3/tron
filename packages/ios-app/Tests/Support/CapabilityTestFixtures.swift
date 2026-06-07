import Foundation
@testable import TronMobile

func testCapabilityIdentity(
    modelPrimitiveName: String = "execute",
    operationName: String? = "file_read",
    traceId: String? = "trace-test",
    rootInvocationId: String? = "invocation-test",
    themeColor: String? = nil,
    presentationHints: [String: AnyCodable]? = nil
) -> CapabilityIdentity {
    CapabilityIdentity(
        modelPrimitiveName: modelPrimitiveName,
        operationName: operationName,
        traceId: traceId,
        rootInvocationId: rootInvocationId,
        themeColor: themeColor,
        presentationHints: presentationHints
    )
}

func testUserInteractionCapabilityIdentity(modelPrimitiveName: String = "execute") -> CapabilityIdentity {
    CapabilityIdentity(
        modelPrimitiveName: modelPrimitiveName,
        operationName: "ask_user",
        traceId: "trace-ask-user-test",
        rootInvocationId: "invocation-ask-user-test"
    )
}

func testCapabilityInvocation(
    id: String = "call_test",
    status: CapabilityInvocationStatus = .success,
    arguments: String = "{}",
    result: String? = nil,
    details: [String: AnyCodable]? = nil,
    durationMs: Int? = nil,
    generatedAt: Date? = nil,
    startedAt: Date? = nil,
    completedAt: Date? = nil,
    identity: CapabilityIdentity = testCapabilityIdentity()
) -> CapabilityInvocationData {
    CapabilityInvocationData(
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

func testCapabilityResult(
    id: String = "call_test",
    content: String = "ok",
    isError: Bool = false,
    identity: CapabilityIdentity = testCapabilityIdentity()
) -> CapabilityInvocationResultData {
    CapabilityInvocationResultData(
        id: id,
        content: content,
        isError: isError,
        identity: identity,
        arguments: nil,
        durationMs: nil,
        details: nil
    )
}
