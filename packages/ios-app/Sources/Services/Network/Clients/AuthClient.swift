import Foundation

/// Client for auth.* RPC methods.
/// Reads and writes provider API keys and OAuth tokens stored in auth.json.
@MainActor
final class AuthClient {
    private unowned let transport: RPCTransport

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Auth Methods

    /// Get masked auth state for all providers and services.
    func get() async throws -> AuthState {
        let ws = try transport.requireConnection()
        let result: AuthState = try await ws.send(
            method: "auth.get",
            params: EmptyParams()
        )
        return result
    }

    /// Update auth for a provider or service. Returns updated masked state.
    func update(_ params: AuthUpdateParams) async throws -> AuthState {
        let ws = try transport.requireConnection()
        let result: AuthState = try await ws.send(
            method: "auth.update",
            params: params
        )
        return result
    }

    /// Clear auth for a provider or service. Returns updated masked state.
    func clear(_ params: AuthClearParams) async throws -> AuthState {
        let ws = try transport.requireConnection()
        let result: AuthState = try await ws.send(
            method: "auth.clear",
            params: params
        )
        return result
    }

    // MARK: - OAuth Flow

    /// Begin an OAuth flow: returns flow ID and authorization URL.
    func oauthBegin(provider: String) async throws -> OAuthBeginResponse {
        let ws = try transport.requireConnection()
        return try await ws.send(
            method: "auth.oauthBegin",
            params: OAuthBeginParams(provider: provider)
        )
    }

    /// Complete an OAuth flow: exchange code for tokens, save to auth.json.
    func oauthComplete(flowId: String, code: String, label: String) async throws -> AuthState {
        let ws = try transport.requireConnection()
        return try await ws.send(
            method: "auth.oauthComplete",
            params: OAuthCompleteParams(flowId: flowId, code: code, label: label)
        )
    }

    /// Rename an OAuth account label.
    func renameAccount(provider: String, oldLabel: String, newLabel: String) async throws -> AuthState {
        let ws = try transport.requireConnection()
        return try await ws.send(
            method: "auth.renameAccount",
            params: RenameAccountParams(provider: provider, oldLabel: oldLabel, newLabel: newLabel)
        )
    }

    // MARK: - Multi-Credential Management

    /// Set the active credential for a provider.
    func setActive(provider: String, credential: ActiveCredentialParam) async throws -> AuthState {
        let ws = try transport.requireConnection()
        return try await ws.send(
            method: "auth.setActive",
            params: SetActiveParams(provider: provider, credential: credential)
        )
    }

    /// Remove an OAuth account by label.
    func removeAccount(provider: String, label: String) async throws -> AuthState {
        let ws = try transport.requireConnection()
        return try await ws.send(
            method: "auth.removeAccount",
            params: RemoveAccountParams(provider: provider, label: label)
        )
    }

    /// Remove a named API key by label.
    func removeApiKey(provider: String, label: String) async throws -> AuthState {
        let ws = try transport.requireConnection()
        return try await ws.send(
            method: "auth.removeApiKey",
            params: RemoveApiKeyParams(provider: provider, label: label)
        )
    }

    /// Add a named API key for a provider.
    func addNamedApiKey(provider: String, label: String, key: String) async throws -> AuthState {
        let ws = try transport.requireConnection()
        return try await ws.send(
            method: "auth.update",
            params: AddNamedApiKeyParams(provider: provider, apiKey: key, apiKeyLabel: label)
        )
    }
}
