import Foundation

/// Typed client for the connection-instance owner. It only receives redacted
/// projections; credential values remain in the Mac-owned secure store while
/// non-secret MCP transport configuration is sent only to the connection owner. Reads are disposable, while accepted mutations use the
/// shared receipt executor and continue after presentation dismissal.
@MainActor
final class IntegrationsRPCClient {
    typealias Request = @MainActor @Sendable (String, JSONValue) async throws -> JSONValue
    private let requestValue: Request
    private let mutationExecutor: ConfirmedMutationExecutor?
    private let uuidSource: UUIDSource

    init(request: @escaping Request, mutationExecutor: ConfirmedMutationExecutor? = nil, uuidSource: UUIDSource = .random) {
        self.requestValue = request
        self.mutationExecutor = mutationExecutor
        self.uuidSource = uuidSource
    }

    func snapshot() async throws -> IntegrationSnapshot {
        let value: IntegrationSnapshot = try await request("connections.list")
        guard value.definitions.count <= 64, value.instances.count <= 256,
              value.capabilities.count <= 1_024, value.setupOperations.count <= 256,
              value.stateRevision >= 0,
              value.instances.allSatisfy({ !$0.id.isEmpty && !$0.definitionId.isEmpty }),
              value.capabilities.allSatisfy({ $0.id.isEmpty == false && $0.provenance.owner == "connection" }) else {
            throw invalidResponse()
        }
        return value
    }

    func beginSetup(instanceID: String, definitionID: String, method: String) async throws -> IntegrationSetupStarted {
        struct Params: Encodable { let instanceId: String; let definitionId: String; let method: String }
        let value: IntegrationSetupStarted = try await mutate(
            "connections.setup.begin",
            parameters: Params(instanceId: instanceID, definitionId: definitionID, method: method)
        )
        guard value.instanceId == instanceID, value.definitionId == definitionID,
              value.method == method, value.status == "pending", !value.operationId.isEmpty else {
            throw invalidResponse()
        }
        return value
    }

    func completeSetup(
        operationID: String,
        instanceID: String,
        providerAccountID: String,
        scope: String?,
        credentialRef: String,
        policy: IntegrationPolicy,
        configuration: IntegrationSetupConfiguration?
    ) async throws -> IntegrationSetupCompleted {
        struct Params: Encodable {
            let operationId: String
            let instanceId: String
            let providerAccountId: String
            let scope: String?
            let credentialRef: String
            let policy: IntegrationPolicy
            let configuration: IntegrationSetupConfiguration?
        }
        let value: IntegrationSetupCompleted = try await mutate(
            "connections.setup.complete",
            parameters: Params(operationId: operationID, instanceId: instanceID, providerAccountId: providerAccountID, scope: scope, credentialRef: credentialRef, policy: policy, configuration: configuration)
        )
        guard value.id == instanceID, !value.definitionId.isEmpty, value.setupRevision >= 1 else { throw invalidResponse() }
        return value
    }

    func updatePolicy(instanceID: String, expectedSetupRevision: Int, policy: IntegrationPolicy) async throws -> IntegrationSetupCompleted {
        struct Params: Encodable { let instanceId: String; let expectedSetupRevision: Int; let policy: IntegrationPolicy }
        let value: IntegrationSetupCompleted = try await mutate("connections.policy.update", parameters: Params(instanceId: instanceID, expectedSetupRevision: expectedSetupRevision, policy: policy))
        guard value.id == instanceID, value.setupRevision >= 1 else { throw invalidResponse() }
        return value
    }

    func disconnect(instanceID: String) async throws -> IntegrationSetupCompleted {
        struct Params: Encodable { let instanceId: String }
        let value: IntegrationSetupCompleted = try await mutate("connections.disconnect", parameters: Params(instanceId: instanceID))
        guard value.id == instanceID, value.health == "disconnected", value.policy.enabled == false else { throw invalidResponse() }
        return value
    }

    private func request<Response: Decodable>(_ method: String, _ parameters: some Encodable = EmptyParams()) async throws -> Response {
        try await requestValue(method, JSONValue.encode(parameters)).decode(Response.self)
    }

    private func mutate<Response: Decodable>(_ method: String, parameters: some Encodable) async throws -> Response {
        guard let mutationExecutor else { throw needsSelectedGateway() }
        let commandID = uuidSource.next().uuidString.lowercased()
        var object = try JSONValue.encode(parameters).objectValue ?? [:]
        object["commandId"] = .string(commandID)
        let value = try await mutationExecutor.performValue(method: method, commandID: commandID) { [requestValue] in
            try await requestValue(method, .object(object))
        }
        return try value.decode(Response.self)
    }

    private func needsSelectedGateway() -> GatewayFailure {
        GatewayFailure(code: "needs_server", message: "Select this Gateway before changing integrations.", retryable: false, details: nil)
    }

    private func invalidResponse() -> GatewayFailure {
        GatewayFailure(code: "invalid_response", message: "The integration response is invalid.", retryable: false, details: nil)
    }
}
