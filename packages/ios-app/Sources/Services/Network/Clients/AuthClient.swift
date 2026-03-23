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
}
