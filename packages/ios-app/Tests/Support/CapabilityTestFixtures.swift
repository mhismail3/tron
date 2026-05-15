import Foundation
@testable import TronMobile

func testCapabilityIdentity(
    modelPrimitiveName: String = "execute",
    contractId: String? = "filesystem::read_file",
    implementationId: String? = "first_party.filesystem.v1.read_file",
    functionId: String? = "filesystem::read_file",
    bindingDecisionId: String? = "binding_decision_test"
) -> CapabilityIdentity {
    CapabilityIdentity(
        modelPrimitiveName: modelPrimitiveName,
        contractId: contractId,
        implementationId: implementationId,
        functionId: functionId,
        pluginId: "first_party.filesystem",
        workerId: "filesystem-worker",
        schemaDigest: "sha256:test",
        catalogRevision: 7,
        trustTier: "first_party_signed",
        riskLevel: "low",
        effectClass: "read",
        traceId: "trace-test",
        rootInvocationId: "invocation-test",
        bindingDecisionId: bindingDecisionId
    )
}

func testUserInteractionCapabilityIdentity(modelPrimitiveName: String = "execute") -> CapabilityIdentity {
    CapabilityIdentity(
        modelPrimitiveName: modelPrimitiveName,
        contractId: "agent::ask_user",
        implementationId: "first_party.agent.v1.ask_user",
        functionId: "agent::ask_user",
        pluginId: "first_party.agent",
        workerId: "agent-worker",
        schemaDigest: "sha256:ask-user-test",
        catalogRevision: 7,
        trustTier: "first_party_signed",
        riskLevel: "medium",
        effectClass: "interaction",
        traceId: "trace-ask-user-test",
        rootInvocationId: "invocation-ask-user-test",
        bindingDecisionId: "binding_decision_ask_user_test"
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
