import Foundation

/// Client for skill-related RPC methods.
/// Handles listing, getting, refreshing, and removing skills.
@MainActor
final class SkillClient {
    private weak var transport: (any RPCTransport)?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Access transport safely, throwing if deallocated during server change.
    private func requireTransport() throws -> any RPCTransport {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        return transport
    }

    /// List available skills
    func list(sessionId: String? = nil, source: String? = nil) async throws -> SkillListResponse {
        let ws = try requireTransport().requireConnection()

        let params = SkillListParams(
            sessionId: sessionId ?? transport?.currentSessionId,
            source: source
        )
        return try await ws.send(method: "skill.list", params: params)
    }

    /// Get a skill by name
    func get(name: String, sessionId: String? = nil) async throws -> SkillGetResponse {
        let ws = try requireTransport().requireConnection()

        let params = SkillGetParams(
            sessionId: sessionId ?? transport?.currentSessionId,
            name: name
        )
        return try await ws.send(method: "skill.get", params: params)
    }

    /// Refresh skills cache
    func refresh(sessionId: String? = nil) async throws -> SkillRefreshResponse {
        let ws = try requireTransport().requireConnection()

        let params = SkillRefreshParams(sessionId: sessionId ?? transport?.currentSessionId)
        return try await ws.send(method: "skill.refresh", params: params)
    }

    /// Remove a skill from session context
    func remove(sessionId: String, skillName: String) async throws -> SkillRemoveResponse {
        let ws = try requireTransport().requireConnection()

        let params = SkillRemoveParams(sessionId: sessionId, skillName: skillName)
        return try await ws.send(method: "skill.remove", params: params)
    }
}
