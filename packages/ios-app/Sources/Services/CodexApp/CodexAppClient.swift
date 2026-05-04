import Foundation

@MainActor
final class CodexAppClient {
    let transport: any CodexAppTransporting

    init(transport: any CodexAppTransporting) {
        self.transport = transport
    }

    func connect() async throws -> CodexInitializeResponse {
        try await transport.connect()
        let response = try await initialize()
        try await transport.notify(method: "initialized", params: nil)
        return response
    }

    func disconnect() async {
        await transport.disconnect()
    }

    func initialize() async throws -> CodexInitializeResponse {
        let result = try await transport.send(
            method: "initialize",
            params: try CodexInitializeParams().codexParams(),
            timeout: 10
        )
        return try Self.decode(CodexInitializeResponse.self, from: result)
    }

    func listThreads(limit: Int = 100, cursor: String? = nil) async throws -> CodexThreadListResponse {
        let result = try await transport.send(
            method: "thread/list",
            params: try CodexThreadListParams(cursor: cursor, limit: limit).codexParams(),
            timeout: nil
        )
        return try Self.decode(CodexThreadListResponse.self, from: result)
    }

    func startThread(_ params: CodexThreadStartParams) async throws -> CodexThreadStartResponse {
        let result = try await transport.send(
            method: "thread/start",
            params: try params.codexParams(),
            timeout: nil
        )
        return try Self.decode(CodexThreadStartResponse.self, from: result)
    }

    func resumeThread(threadId: String) async throws -> CodexThreadResumeResponse {
        let result = try await transport.send(
            method: "thread/resume",
            params: try CodexThreadResumeParams(threadId: threadId).codexParams(),
            timeout: nil
        )
        return try Self.decode(CodexThreadResumeResponse.self, from: result)
    }

    func archiveThread(threadId: String) async throws {
        _ = try await transport.send(
            method: "thread/archive",
            params: try CodexThreadArchiveParams(threadId: threadId).codexParams(),
            timeout: nil
        )
    }

    func startTurn(_ params: CodexTurnStartParams) async throws -> CodexTurnStartResponse {
        let result = try await transport.send(
            method: "turn/start",
            params: try params.codexParams(),
            timeout: nil
        )
        return try Self.decode(CodexTurnStartResponse.self, from: result)
    }

    func interruptTurn(threadId: String, turnId: String?) async throws {
        _ = try await transport.send(
            method: "turn/interrupt",
            params: try CodexTurnInterruptParams(threadId: threadId, turnId: turnId).codexParams(),
            timeout: nil
        )
    }

    func listModels() async throws -> CodexModelListResponse {
        let result = try await transport.send(method: "model/list", params: nil, timeout: nil)
        return try Self.decode(CodexModelListResponse.self, from: result)
    }

    func readConfig() async throws -> CodexConfigReadResponse {
        let result = try await transport.send(
            method: "config/read",
            params: try CodexConfigReadParams(includeLayers: false).codexParams(),
            timeout: nil
        )
        return try Self.decode(CodexConfigReadResponse.self, from: result)
    }

    func writeConfigValue(
        keyPath: String,
        value: AnyCodable,
        mergeStrategy: CodexConfigMergeStrategy = .replace
    ) async throws {
        _ = try await transport.send(
            method: "config/value/write",
            params: try CodexConfigWriteParams(
                keyPath: keyPath,
                value: value,
                mergeStrategy: mergeStrategy
            ).codexParams(),
            timeout: nil
        )
    }

    func readAccount(refreshToken: Bool = false) async throws -> CodexAccountResponse {
        let result = try await transport.send(
            method: "account/read",
            params: try CodexAccountReadParams(refreshToken: refreshToken).codexParams(),
            timeout: nil
        )
        return try Self.decode(CodexAccountResponse.self, from: result)
    }

    func startAccountLogin(_ params: CodexAccountLoginStartParams) async throws -> CodexAccountLoginStartResponse {
        let result = try await transport.send(
            method: "account/login/start",
            params: try params.codexParams(),
            timeout: nil
        )
        return try Self.decode(CodexAccountLoginStartResponse.self, from: result)
    }

    func cancelAccountLogin(loginId: String) async throws {
        _ = try await transport.send(
            method: "account/login/cancel",
            params: try CodexAccountLoginCancelParams(loginId: loginId).codexParams(),
            timeout: nil
        )
    }

    func logoutAccount() async throws {
        _ = try await transport.send(method: "account/logout", params: nil, timeout: nil)
    }

    func resolveApproval(_ request: CodexApprovalRequest, decision: CodexApprovalDecision) async throws {
        let response = CodexJSONRPCServerResponse(
            id: request.requestId,
            result: ["decision": decision.payload]
        )
        try await transport.respond(response)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: AnyCodable]) throws -> T {
        let data = try JSONEncoder().encode(dictionary)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
