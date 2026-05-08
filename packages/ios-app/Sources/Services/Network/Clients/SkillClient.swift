import Foundation

/// Client for skill-related engine capabilities.
/// Handles listing, getting, refreshing, and removing skills.
final class SkillClient: EngineDomainClient {

    /// List available skills
    func list(sessionId: String? = nil, source: String? = nil) async throws -> SkillListResponse {
        _ = try requireTransport().requireConnection()

        let params = SkillListParams(
            sessionId: sessionId ?? currentTransport?.currentSessionId,
            source: source
        )
        return try await invokeRead("skills::list", params)
    }

    /// Get a skill by name
    func get(name: String, sessionId: String? = nil) async throws -> SkillGetResponse {
        _ = try requireTransport().requireConnection()

        let params = SkillGetParams(
            sessionId: sessionId ?? currentTransport?.currentSessionId,
            name: name
        )
        return try await invokeRead("skills::get", params)
    }

    /// Refresh skills cache
    func refresh(sessionId: String? = nil, idempotencyKey: EngineIdempotencyKey) async throws -> SkillRefreshResponse {
        _ = try requireTransport().requireConnection()

        let params = SkillRefreshParams(sessionId: sessionId ?? currentTransport?.currentSessionId)
        return try await invokeWrite("skills::refresh", params, idempotencyKey: idempotencyKey)
    }

    /// Remove a skill from session context
    func remove(
        sessionId: String,
        skillName: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> SkillRemoveResponse {
        _ = try requireTransport().requireConnection()

        let params = SkillDeactivateParams(sessionId: sessionId, skillName: skillName)
        let result: SkillDeactivateResult = try await invokeWrite(
            "skills::deactivate",
            params,
            idempotencyKey: idempotencyKey
        )
        return SkillRemoveResponse(success: result.success, error: nil)
    }
}
