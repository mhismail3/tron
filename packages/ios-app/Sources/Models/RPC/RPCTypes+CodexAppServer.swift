import Foundation

/// Server-owned Codex App Server status returned by `codexApp.status`.
struct CodexAppServerStatusResult: Decodable, Equatable, Sendable {
    struct Endpoint: Decodable, Equatable, Sendable {
        let scheme: String
        /// `nil` means use the active paired Tron server host.
        let host: String?
        let port: Int
        let path: String
        let requiresToken: Bool
        let bearerToken: String?

        init(
            scheme: String = "ws",
            host: String? = nil,
            port: Int = 4500,
            path: String = "",
            requiresToken: Bool = true,
            bearerToken: String? = nil
        ) {
            self.scheme = scheme
            self.host = host
            self.port = port
            self.path = path
            self.requiresToken = requiresToken
            self.bearerToken = bearerToken
        }
    }

    struct Defaults: Decodable, Equatable, Sendable {
        let preferredCwd: String?
        let preferredModel: String?
        let approvalPolicy: CodexApprovalPolicy
        let sandboxMode: CodexSandboxMode

        private enum CodingKeys: String, CodingKey {
            case preferredCwd, preferredModel, approvalPolicy, sandboxMode
        }

        init(
            preferredCwd: String? = nil,
            preferredModel: String? = nil,
            approvalPolicy: CodexApprovalPolicy = .onRequest,
            sandboxMode: CodexSandboxMode = .workspaceWrite
        ) {
            self.preferredCwd = preferredCwd
            self.preferredModel = preferredModel
            self.approvalPolicy = approvalPolicy
            self.sandboxMode = sandboxMode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preferredCwd = try? container.decodeIfPresent(String.self, forKey: .preferredCwd)
            preferredModel = try? container.decodeIfPresent(String.self, forKey: .preferredModel)
            approvalPolicy = (try? container.decodeIfPresent(CodexApprovalPolicy.self, forKey: .approvalPolicy)) ?? .onRequest
            sandboxMode = (try? container.decodeIfPresent(CodexSandboxMode.self, forKey: .sandboxMode)) ?? .workspaceWrite
        }
    }

    let enabled: Bool
    let state: String
    let endpoint: Endpoint?
    let defaults: Defaults
    let listenUrl: String
    let pid: Int?
    let lastError: String?

    init(
        enabled: Bool = true,
        state: String = "running",
        endpoint: Endpoint? = Endpoint(bearerToken: "codex-token"),
        defaults: Defaults = Defaults(),
        listenUrl: String = "ws://0.0.0.0:4500",
        pid: Int? = 123,
        lastError: String? = nil
    ) {
        self.enabled = enabled
        self.state = state
        self.endpoint = endpoint
        self.defaults = defaults
        self.listenUrl = listenUrl
        self.pid = pid
        self.lastError = lastError
    }

    var isRunning: Bool {
        enabled && state == "running" && endpoint != nil
    }
}
