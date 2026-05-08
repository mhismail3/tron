import Foundation

/// Client for auth engine capabilities.
/// Reads and writes provider API keys and OAuth tokens stored in auth.json.
final class AuthClient: EngineDomainClient {

    // MARK: - Auth Methods

    /// Get masked auth state for all providers and services.
    func get() async throws -> AuthState {
        let result: AuthState = try await invokeRead(
            "auth::get",
            EmptyParams()
        )
        return result
    }

    /// Update auth for a provider or service. Returns updated masked state.
    func update(_ params: AuthUpdateParams, idempotencyKey: EngineIdempotencyKey) async throws -> AuthState {
        let result: AuthState = try await invokeWrite(
            "auth::update",
            params,
            idempotencyKey: idempotencyKey
        )
        return result
    }

    /// Clear auth for a provider or service. Returns updated masked state.
    func clear(_ params: AuthClearParams, idempotencyKey: EngineIdempotencyKey) async throws -> AuthState {
        let result: AuthState = try await invokeWrite(
            "auth::clear",
            params,
            idempotencyKey: idempotencyKey
        )
        return result
    }

    // MARK: - OAuth Flow

    /// Begin an OAuth flow: returns flow ID and authorization URL.
    func oauthBegin(provider: String, idempotencyKey: EngineIdempotencyKey) async throws -> OAuthBeginResponse {
        return try await invokeWrite(
            "auth::oauth_begin",
            OAuthBeginParams(provider: provider),
            idempotencyKey: idempotencyKey
        )
    }

    /// Complete an OAuth flow: exchange code for tokens, save to auth.json.
    func oauthComplete(
        flowId: String,
        code: String,
        label: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AuthState {
        return try await invokeWrite(
            "auth::oauth_complete",
            OAuthCompleteParams(flowId: flowId, code: code, label: label),
            idempotencyKey: idempotencyKey
        )
    }

    /// Rename an OAuth account label.
    func renameAccount(
        provider: String,
        oldLabel: String,
        newLabel: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AuthState {
        return try await invokeWrite(
            "auth::rename_account",
            RenameAccountParams(provider: provider, oldLabel: oldLabel, newLabel: newLabel),
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Multi-Credential Management

    /// Set the active credential for a provider.
    func setActive(
        provider: String,
        credential: ActiveCredentialParam,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AuthState {
        return try await invokeWrite(
            "auth::set_active",
            SetActiveParams(provider: provider, credential: credential),
            idempotencyKey: idempotencyKey
        )
    }

    /// Remove an OAuth account by label.
    func removeAccount(
        provider: String,
        label: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AuthState {
        return try await invokeWrite(
            "auth::remove_account",
            RemoveAccountParams(provider: provider, label: label),
            idempotencyKey: idempotencyKey
        )
    }

    /// Remove a named API key by label.
    func removeApiKey(
        provider: String,
        label: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AuthState {
        return try await invokeWrite(
            "auth::remove_api_key",
            RemoveApiKeyParams(provider: provider, label: label),
            idempotencyKey: idempotencyKey
        )
    }

    /// Add a named API key for a provider.
    func addNamedApiKey(
        provider: String,
        label: String,
        key: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AuthState {
        return try await invokeWrite(
            "auth::update",
            AddNamedApiKeyParams(provider: provider, apiKey: key, apiKeyLabel: label),
            idempotencyKey: idempotencyKey
        )
    }
}
