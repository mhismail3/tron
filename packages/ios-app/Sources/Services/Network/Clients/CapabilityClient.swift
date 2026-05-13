import Foundation

/// Client for capability-native engine administration and primitive calls.
///
/// The model still sees only `search`, `inspect`, and `execute`; this client is
/// the operator/UI path for the same live capability registry, plugin, binding,
/// policy, audit, and conformance records.
final class CapabilityClient: EngineDomainClient {

    func status(includeSnapshot: Bool = false) async throws -> CapabilityStatusDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "capability::status",
            StatusParams(includeSnapshot: includeSnapshot),
            context: readContext
        )
    }

    func registrySnapshot(
        includeDocuments: Bool = true,
        includeBindings: Bool = true
    ) async throws -> CapabilityRegistrySnapshotDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "capability::registry_snapshot",
            SnapshotParams(includeDocuments: includeDocuments, includeBindings: includeBindings),
            context: readContext
        )
    }

    func search(_ request: CapabilitySearchRequestDTO) async throws -> CapabilitySearchResponseDTO {
        _ = try requireTransport().requireConnection()
        let result: CapabilityPrimitiveResultDTO = try await invokeRead(
            "capability::search",
            request,
            context: operatorSearchContext
        )
        return try decodeDetails(CapabilitySearchResponseDTO.self, from: result)
    }

    func inspect(
        capabilityId: String? = nil,
        contractId: String? = nil,
        implementationId: String? = nil,
        functionId: String? = nil
    ) async throws -> CapabilityInspectionDTO {
        _ = try requireTransport().requireConnection()
        let result: CapabilityPrimitiveResultDTO = try await invokeRead(
            "capability::inspect",
            InspectParams(
                capabilityId: capabilityId,
                contractId: contractId,
                implementationId: implementationId,
                functionId: functionId
            ),
            context: primitiveContext
        )
        return try decodeDetails(CapabilityInspectionDTO.self, from: result)
    }

    func executeInvoke(
        contractId: String? = nil,
        implementationId: String? = nil,
        functionId: String? = nil,
        payload: [String: AnyCodable],
        expectedRevision: UInt64? = nil,
        expectedSchemaDigest: String? = nil,
        inspectionHandle: String? = nil,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> CapabilityExecutionDTO {
        _ = try requireTransport().requireConnection()
        let result: CapabilityPrimitiveResultDTO = try await invokeWrite(
            "capability::execute",
            ExecuteParams(
                mode: "invoke",
                contractId: contractId,
                implementationId: implementationId,
                functionId: functionId,
                payload: payload,
                expectedRevision: expectedRevision,
                expectedSchemaDigest: expectedSchemaDigest,
                inspectionHandle: inspectionHandle,
                idempotencyKey: idempotencyKey.rawValue,
                reason: reason
            ),
            idempotencyKey: idempotencyKey,
            context: primitiveContext
        )
        return try decodeDetails(CapabilityExecutionDTO.self, from: result)
    }

    func executeProgram(
        code: String,
        args: [String: AnyCodable] = [:],
        allowedContracts: [String] = [],
        allowedImplementations: [String] = [],
        timeoutMs: UInt64? = nil,
        budget: AnyCodable? = nil,
        inspectionHandle: String,
        expectedRevision: UInt64,
        expectedSchemaDigest: String,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> CapabilityProgramExecutionDTO {
        _ = try requireTransport().requireConnection()
        let result: CapabilityPrimitiveResultDTO = try await invokeWrite(
            "capability::execute",
            ProgramExecuteParams(
                mode: "program",
                language: "javascript",
                code: code,
                args: args,
                allowedContracts: allowedContracts,
                allowedImplementations: allowedImplementations,
                timeoutMs: timeoutMs,
                budget: budget,
                inspectionHandle: inspectionHandle,
                expectedRevision: expectedRevision,
                expectedSchemaDigest: expectedSchemaDigest,
                idempotencyKey: idempotencyKey.rawValue,
                reason: reason
            ),
            idempotencyKey: idempotencyKey,
            context: programContext
        )
        return try decodeDetails(CapabilityProgramExecutionDTO.self, from: result)
    }

    func auditQuery(_ query: CapabilityAuditQueryDTO) async throws -> CapabilityAuditQueryResultDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "capability::audit_query",
            query,
            context: readContext
        )
    }

    func programRunList(
        _ query: CapabilityProgramRunQueryDTO = CapabilityProgramRunQueryDTO(
            traceId: nil,
            status: nil,
            limit: 50,
            revealPayloads: false
        )
    ) async throws -> CapabilityProgramRunQueryResultDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "capability::program_run_list",
            query,
            context: readContext
        )
    }

    func listBindings() async throws -> [CapabilityBindingDTO] {
        _ = try requireTransport().requireConnection()
        let result: BindingListResult = try await invokeRead(
            "capability::binding_list",
            EmptyParams(),
            context: readContext
        )
        return result.bindings
    }

    func setBinding(
        contractId: String,
        selectedImplementation: String,
        scopeKind: String = "system",
        scopeValue: String = "default",
        selectionPolicy: String = "explicit",
        secondaryImplementations: [String] = [],
        priority: Int = 0,
        enabled: Bool = true,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "capability::binding_set",
            BindingSetParams(
                contractId: contractId,
                scopeKind: scopeKind,
                scopeValue: scopeValue,
                selectedImplementation: selectedImplementation,
                selectionPolicy: selectionPolicy,
                secondaryImplementations: secondaryImplementations,
                priority: priority,
                enabled: enabled,
                reason: reason
            ),
            idempotencyKey: idempotencyKey,
            context: writeContext
        )
    }

    func listPlugins() async throws -> [CapabilityPluginManifestDTO] {
        _ = try requireTransport().requireConnection()
        let result: PluginListResult = try await invokeRead(
            "capability::plugin_list",
            EmptyParams(),
            context: readContext
        )
        return result.plugins
    }

    func inspectPlugin(_ pluginId: String) async throws -> CapabilityPluginInspectDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "capability::plugin_inspect",
            PluginIdParams(pluginId: pluginId),
            context: readContext
        )
    }

    func installPlugin(
        manifest: CapabilityPluginManifestDTO,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        try await pluginManifestMutation(
            functionId: "capability::plugin_install",
            manifest: manifest,
            reason: reason,
            idempotencyKey: idempotencyKey
        )
    }

    func updatePlugin(
        manifest: CapabilityPluginManifestDTO,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        try await pluginManifestMutation(
            functionId: "capability::plugin_update",
            manifest: manifest,
            reason: reason,
            idempotencyKey: idempotencyKey
        )
    }

    func setPluginState(
        pluginId: String,
        state: String,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "capability::plugin_set_state",
            PluginStateParams(pluginId: pluginId, state: state, reason: reason),
            idempotencyKey: idempotencyKey,
            context: writeContext
        )
    }

    func promotePlugin(
        pluginId: String,
        targetVisibility: String,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "capability::plugin_promote",
            PluginPromoteParams(pluginId: pluginId, targetVisibility: targetVisibility, reason: reason),
            idempotencyKey: idempotencyKey,
            context: writeContext
        )
    }

    func runConformance(
        pluginId: String,
        implementationId: String? = nil,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "capability::conformance_run",
            ConformanceRunParams(pluginId: pluginId, implementationId: implementationId, reason: reason),
            idempotencyKey: idempotencyKey,
            context: writeContext
        )
    }

    func setImplementationState(
        implementationId: String,
        state: String,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "capability::implementation_set_state",
            ImplementationStateParams(implementationId: implementationId, state: state, reason: reason),
            idempotencyKey: idempotencyKey,
            context: writeContext
        )
    }

    func getPolicy(policyId: String? = nil) async throws -> CapabilityPolicyGetDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "capability::policy_get",
            PolicyGetParams(policyId: policyId),
            context: readContext
        )
    }

    func validatePolicy(
        _ policy: CapabilityPolicyDTO,
        policyId: String? = nil
    ) async throws -> CapabilityPolicyValidationDTO {
        _ = try requireTransport().requireConnection()
        return try await invokeRead(
            "capability::policy_validate",
            PolicyValidateParams(policyId: policyId, policy: policy),
            context: readContext
        )
    }

    func updatePolicy(
        policyId: String,
        policy: CapabilityPolicyDTO,
        reason: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "capability::policy_update",
            PolicyUpdateParams(policyId: policyId, policy: policy, reason: reason),
            idempotencyKey: idempotencyKey,
            context: writeContext
        )
    }

    private func pluginManifestMutation(
        functionId: EngineFunctionId,
        manifest: CapabilityPluginManifestDTO,
        reason: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AnyCodable {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            functionId,
            PluginManifestParams(manifest: manifest, reason: reason),
            idempotencyKey: idempotencyKey,
            context: writeContext
        )
    }

    private var primitiveContext: EngineInvocationContext {
        EngineInvocationContext(authorityScopes: [
            "capability.search",
            "capability.inspect",
            "capability.execute"
        ])
    }

    private var operatorSearchContext: EngineInvocationContext {
        EngineInvocationContext(
            authorityScopes: [
                "capability.search",
                "capability.inspect",
                "capability.execute"
            ],
            runtimeMetadata: [
                "capability.searchPolicyId": "operatorConsoleHybridLexical",
                "capability.searchPolicy": #"{"lexical":true,"localVector":true,"cloudEmbeddings":false,"maxResults":50,"requireLocalVector":false,"allowLexicalOnlyWhenDegraded":true}"#
            ]
        )
    }

    private var programContext: EngineInvocationContext {
        EngineInvocationContext(authorityScopes: [
            "capability.search",
            "capability.inspect",
            "capability.execute",
            "capability.allow:program::run_javascript"
        ])
    }

    private var readContext: EngineInvocationContext {
        EngineInvocationContext(authorityScopes: [
            "capability.admin.read",
            "capability.audit.read",
            "capability.policy.read"
        ])
    }

    private var writeContext: EngineInvocationContext {
        EngineInvocationContext(authorityScopes: [
            "capability.admin.read",
            "capability.admin.write",
            "capability.audit.read",
            "capability.plugin.write",
            "capability.policy.write"
        ])
    }

    private func decodeDetails<T: Decodable>(
        _ type: T.Type,
        from result: CapabilityPrimitiveResultDTO
    ) throws -> T {
        guard let details = result.details else {
            throw EngineConnectionError.invalidResponse
        }
        guard JSONSerialization.isValidJSONObject(details.value) else {
            throw EngineConnectionError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: details.value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct StatusParams: Encodable { let includeSnapshot: Bool }
private struct SnapshotParams: Encodable { let includeDocuments: Bool; let includeBindings: Bool }

private struct InspectParams: Encodable {
    let capabilityId: String?
    let contractId: String?
    let implementationId: String?
    let functionId: String?
}

private struct ExecuteParams: Encodable {
    let mode: String
    let contractId: String?
    let implementationId: String?
    let functionId: String?
    let payload: [String: AnyCodable]
    let expectedRevision: UInt64?
    let expectedSchemaDigest: String?
    let inspectionHandle: String?
    let idempotencyKey: String
    let reason: String?
}

private struct ProgramExecuteParams: Encodable {
    let mode: String
    let language: String
    let code: String
    let args: [String: AnyCodable]
    let allowedContracts: [String]
    let allowedImplementations: [String]
    let timeoutMs: UInt64?
    let budget: AnyCodable?
    let inspectionHandle: String
    let expectedRevision: UInt64
    let expectedSchemaDigest: String
    let idempotencyKey: String
    let reason: String?
}

private struct BindingListResult: Decodable { let bindings: [CapabilityBindingDTO] }
private struct PluginListResult: Decodable { let plugins: [CapabilityPluginManifestDTO] }
private struct PluginIdParams: Encodable { let pluginId: String }

private struct BindingSetParams: Encodable {
    let contractId: String
    let scopeKind: String
    let scopeValue: String
    let selectedImplementation: String
    let selectionPolicy: String
    let secondaryImplementations: [String]
    let priority: Int
    let enabled: Bool
    let reason: String?
}

private struct PluginManifestParams: Encodable {
    let manifest: CapabilityPluginManifestDTO
    let reason: String?
}

private struct PluginStateParams: Encodable {
    let pluginId: String
    let state: String
    let reason: String?
}

private struct PluginPromoteParams: Encodable {
    let pluginId: String
    let targetVisibility: String
    let reason: String?
}

private struct ConformanceRunParams: Encodable {
    let pluginId: String
    let implementationId: String?
    let reason: String?
}

private struct ImplementationStateParams: Encodable {
    let implementationId: String
    let state: String
    let reason: String?
}

private struct PolicyGetParams: Encodable { let policyId: String? }

private struct PolicyValidateParams: Encodable {
    let policyId: String?
    let policy: CapabilityPolicyDTO
}

private struct PolicyUpdateParams: Encodable {
    let policyId: String
    let policy: CapabilityPolicyDTO
    let reason: String?
}
