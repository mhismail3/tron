import Foundation

enum CodexAppScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case ws
    case wss

    var id: String { rawValue }
}

enum CodexApprovalPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case onRequest = "onRequest"
    case unlessTrusted = "unlessTrusted"
    case never

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "onRequest", "on-request":
            self = .onRequest
        case "unlessTrusted", "untrusted", "on-failure":
            self = .unlessTrusted
        case "never":
            self = .never
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown Codex approval policy: \(value)"
            )
        }
    }

    var title: String {
        switch self {
        case .onRequest: "On Request"
        case .unlessTrusted: "Unless Trusted"
        case .never: "Never"
        }
    }
}

enum CodexSandboxMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly = "readOnly"
    case workspaceWrite = "workspaceWrite"
    case dangerFullAccess = "dangerFullAccess"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "readOnly", "read-only":
            self = .readOnly
        case "workspaceWrite", "workspace-write":
            self = .workspaceWrite
        case "dangerFullAccess", "danger-full-access":
            self = .dangerFullAccess
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown Codex sandbox mode: \(value)"
            )
        }
    }

    var title: String {
        switch self {
        case .readOnly: "Read Only"
        case .workspaceWrite: "Workspace Write"
        case .dangerFullAccess: "Full Access"
        }
    }
}

struct CodexAppServerConfig: Codable, Equatable, Identifiable, Sendable {
    let serverId: String
    var scheme: CodexAppScheme
    var hostOverride: String?
    var port: Int
    var path: String
    var preferredCwd: String
    var preferredModel: String
    var approvalPolicy: CodexApprovalPolicy
    var sandboxMode: CodexSandboxMode
    var lastConnectedAt: Date?
    var lastUserAgent: String?
    var lastKnownStatus: String?

    var id: String { serverId }

    init(
        serverId: String,
        scheme: CodexAppScheme = .ws,
        hostOverride: String? = nil,
        port: Int = 4500,
        path: String = "",
        preferredCwd: String = "",
        preferredModel: String = "",
        approvalPolicy: CodexApprovalPolicy = .onRequest,
        sandboxMode: CodexSandboxMode = .workspaceWrite,
        lastConnectedAt: Date? = nil,
        lastUserAgent: String? = nil,
        lastKnownStatus: String? = nil
    ) {
        self.serverId = serverId
        self.scheme = scheme
        self.hostOverride = hostOverride
        self.port = port
        self.path = path
        self.preferredCwd = preferredCwd
        self.preferredModel = preferredModel
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
        self.lastConnectedAt = lastConnectedAt
        self.lastUserAgent = lastUserAgent
        self.lastKnownStatus = lastKnownStatus
    }

    func endpoint(activeServer: PairedServer) throws -> CodexAppEndpoint {
        guard (1...65535).contains(port) else {
            throw CodexAppServerConfigError.invalidPort(port)
        }

        let host = Self.normalizedHost(hostOverride?.nilIfEmpty ?? activeServer.host)
        guard !host.isEmpty else {
            throw CodexAppServerConfigError.invalidHost
        }

        let hostComponent = host.contains(":") ? "[\(host)]" : host
        let urlString = "\(scheme.rawValue)://\(hostComponent):\(port)\(Self.normalizedPath(path))"
        guard let url = URL(string: urlString) else {
            throw CodexAppServerConfigError.invalidURL
        }

        return CodexAppEndpoint(
            url: url,
            requiresToken: !Self.isLocalhost(host)
        )
    }

    static func normalizedPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return "" }
        let withoutTrailing = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !withoutTrailing.isEmpty else { return "" }
        return "/\(withoutTrailing)"
    }

    static func normalizedHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    static func isLocalhost(_ host: String) -> Bool {
        let normalized = normalizedHost(host).lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
    }
}

struct CodexAppEndpoint: Equatable, Sendable {
    let url: URL
    let requiresToken: Bool

    func validateSecurity(token: String?, allowInsecureLocalhost: Bool) throws {
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        if allowInsecureLocalhost,
           let host = url.host,
           CodexAppServerConfig.isLocalhost(host) {
            return
        }

        if requiresToken {
            throw CodexAppServerConfigError.missingRemoteToken
        }
    }
}

enum CodexAppServerConfigError: Error, Equatable, LocalizedError {
    case invalidPort(Int)
    case invalidHost
    case invalidURL
    case noActiveServer
    case missingRemoteToken

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "Codex App Server port \(port) is outside 1...65535."
        case .invalidHost: "Codex App Server host is empty."
        case .invalidURL: "Codex App Server URL is invalid."
        case .noActiveServer: "Pair a Tron server first."
        case .missingRemoteToken: "Remote Codex App Server connections require a bearer token."
        }
    }
}

enum CodexAppSecretRedactor {
    static func redact(_ message: String, token: String?) -> String {
        var redacted = message
        if let token, !token.isEmpty {
            redacted = redacted.replacingOccurrences(of: token, with: "<redacted>")
        }
        redacted = redacted.replacing(
            #/Bearer\s+[-._~+/=A-Za-z0-9]+/#,
            with: "Bearer <redacted>"
        )
        return redacted
    }
}
