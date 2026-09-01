import Foundation

typealias WorkspaceInspectionRequest = @Sendable (String, JSONValue) async throws -> JSONValue

struct WorkspaceInspectionService: Sendable {
    private let request: WorkspaceInspectionRequest

    init(client: GatewayClient) {
        request = { method, params in
            try await client.requestValue(method, params)
        }
    }

    init(request: @escaping WorkspaceInspectionRequest) {
        self.request = request
    }

    func inspect(sessionID: String) async throws -> SessionWorkspaceInspection {
        try await decode("session.workspace.inspect", params: sessionParams(sessionID))
    }

    func list(sessionID: String, path: String) async throws -> SessionWorkspaceDirectory {
        var params = sessionParams(sessionID)
        if !path.isEmpty { params["path"] = .string(path) }
        return try await decode("session.workspace.list", params: params)
    }

    func file(sessionID: String, path: String) async throws -> SessionWorkspaceFile {
        try await decode("session.workspace.file", params: sessionParams(sessionID, adding: [
            "path": .string(path),
        ]))
    }

    func diff(
        sessionID: String,
        path: String,
        scope: SessionWorkspaceDiffScope
    ) async throws -> SessionWorkspaceDiff {
        try await decode("session.workspace.git.diff", params: sessionParams(sessionID, adding: [
            "path": .string(path),
            "scope": .string(scope.rawValue),
        ]))
    }

    func history(
        sessionID: String,
        scope: SessionWorkspaceHistoryScope,
        cursor: String? = nil,
        limit: Int = 40
    ) async throws -> SessionWorkspaceHistoryPage {
        precondition((1...100).contains(limit))
        var extra: [String: JSONValue] = [
            "scope": .string(scope.rawValue),
            "limit": .number(Double(limit)),
        ]
        if let cursor { extra["cursor"] = .string(cursor) }
        return try await decode(
            "session.workspace.git.history.list",
            params: sessionParams(sessionID, adding: extra)
        )
    }

    func commit(sessionID: String, oid: String) async throws -> SessionWorkspaceCommitDetail {
        try await decode("session.workspace.git.history.get", params: sessionParams(sessionID, adding: [
            "oid": .string(oid),
        ]))
    }

    private func sessionParams(
        _ sessionID: String,
        adding extra: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        var values = extra
        values["sessionId"] = .string(sessionID)
        return values
    }

    private func decode<T: Decodable>(
        _ method: String,
        params: [String: JSONValue]
    ) async throws -> T {
        let value = try await request(method, .object(params))
        return try value.decode(T.self)
    }
}
