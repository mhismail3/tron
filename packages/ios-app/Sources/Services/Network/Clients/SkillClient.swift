import Foundation

/// Client for skill-related RPC methods.
/// Handles listing, getting, refreshing, and removing skills.
final class SkillClient: RPCDomainClient {

    /// List available skills
    func list(sessionId: String? = nil, source: String? = nil) async throws -> SkillListResponse {
        let ws = try requireTransport().requireConnection()

        let params = SkillListParams(
            sessionId: sessionId ?? currentTransport?.currentSessionId,
            source: source
        )
        return try await ws.send(method: "skill.list", params: params)
    }

    /// Get a skill by name
    func get(name: String, sessionId: String? = nil) async throws -> SkillGetResponse {
        let ws = try requireTransport().requireConnection()

        let params = SkillGetParams(
            sessionId: sessionId ?? currentTransport?.currentSessionId,
            name: name
        )
        return try await ws.send(method: "skill.get", params: params)
    }

    /// Refresh skills cache
    func refresh(sessionId: String? = nil) async throws -> SkillRefreshResponse {
        let ws = try requireTransport().requireConnection()

        let params = SkillRefreshParams(sessionId: sessionId ?? currentTransport?.currentSessionId)
        return try await ws.send(method: "skill.refresh", params: params)
    }

    /// Remove a skill from session context
    func remove(sessionId: String, skillName: String) async throws -> SkillRemoveResponse {
        let ws = try requireTransport().requireConnection()

        let params = SkillRemoveParams(sessionId: sessionId, skillName: skillName)
        return try await ws.send(method: "skill.remove", params: params)
    }
}
