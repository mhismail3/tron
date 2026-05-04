import Foundation

struct CodexInitializeParams: Encodable, Sendable {
    struct ClientInfo: Encodable, Sendable {
        let name: String
        let title: String
        let version: String
    }

    let clientInfo: ClientInfo
    let capabilities: [String: Bool]?

    init(name: String = "tron_ios", title: String = "Tron iOS", version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0", capabilities: [String: Bool]? = nil) {
        clientInfo = ClientInfo(name: name, title: title, version: version)
        self.capabilities = capabilities
    }
}

struct CodexInitializeResponse: Decodable, Equatable, Sendable {
    let userAgent: String?
    let codexHome: String?
    let platformFamily: String?
    let platformOs: String?
}

enum CodexUserInput: Equatable, Sendable {
    case text(String)
    case imageURL(String)
    case localImage(path: String)
}

extension CodexUserInput: Encodable {
    enum CodingKeys: String, CodingKey {
        case type
        case text
        case url
        case path
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image", forKey: .type)
            try container.encode(url, forKey: .url)
        case .localImage(let path):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}

struct CodexThreadStartParams: Encodable, Sendable {
    var model: String?
    var modelProvider: String?
    var cwd: String?
    var approvalPolicy: CodexApprovalPolicy?
    var sandbox: CodexSandboxMode?
    var config: [String: AnyCodable]?
    var baseInstructions: String?
    var developerInstructions: String?
    var experimentalRawEvents: Bool?

    init(
        model: String? = nil,
        modelProvider: String? = nil,
        cwd: String? = nil,
        approvalPolicy: CodexApprovalPolicy? = nil,
        sandbox: CodexSandboxMode? = nil,
        config: [String: AnyCodable]? = nil,
        baseInstructions: String? = nil,
        developerInstructions: String? = nil,
        experimentalRawEvents: Bool? = nil
    ) {
        self.model = model
        self.modelProvider = modelProvider
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.config = config
        self.baseInstructions = baseInstructions
        self.developerInstructions = developerInstructions
        self.experimentalRawEvents = experimentalRawEvents
    }
}

struct CodexTurnStartParams: Encodable, Sendable {
    let threadId: String
    let input: [CodexUserInput]
    let cwd: String?
    let approvalPolicy: CodexApprovalPolicy?
    let sandboxPolicy: CodexSandboxPolicy?
    let model: String?
    let effort: String?
    let summary: String?
}

struct CodexSandboxPolicy: Encodable, Equatable, Sendable {
    let type: CodexSandboxMode
    let writableRoots: [String]?
    let networkAccess: Bool?

    init(type: CodexSandboxMode, writableRoots: [String]? = nil, networkAccess: Bool? = nil) {
        self.type = type
        self.writableRoots = writableRoots
        self.networkAccess = networkAccess
    }
}

struct CodexThreadListParams: Encodable, Sendable {
    let cursor: String?
    let limit: Int?
}

struct CodexThreadResumeParams: Encodable, Sendable {
    let threadId: String
}

struct CodexThreadArchiveParams: Encodable, Sendable {
    let threadId: String
}

struct CodexTurnInterruptParams: Encodable, Sendable {
    let threadId: String
    let turnId: String?
}

struct CodexConfigReadParams: Encodable, Sendable {
    let includeLayers: Bool
}

enum CodexConfigMergeStrategy: String, Encodable, Sendable {
    case replace
    case upsert
}

struct CodexConfigWriteParams: Encodable, Sendable {
    let keyPath: String
    let value: AnyCodable
    let mergeStrategy: CodexConfigMergeStrategy
}

struct CodexAccountReadParams: Encodable, Sendable {
    let refreshToken: Bool
}

enum CodexAccountLoginType: String, Encodable, Sendable {
    case apiKey
    case chatgpt
    case chatgptDeviceCode
    case chatgptAuthTokens
}

struct CodexAccountLoginStartParams: Encodable, Sendable {
    let type: CodexAccountLoginType
    let apiKey: String?
    let accessToken: String?
    let chatgptAccountId: String?
    let chatgptPlanType: String?

    init(
        type: CodexAccountLoginType,
        apiKey: String? = nil,
        accessToken: String? = nil,
        chatgptAccountId: String? = nil,
        chatgptPlanType: String? = nil
    ) {
        self.type = type
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.chatgptAccountId = chatgptAccountId
        self.chatgptPlanType = chatgptPlanType
    }
}

struct CodexAccountLoginCancelParams: Encodable, Sendable {
    let loginId: String
}

struct CodexAccountLoginStartResponse: Decodable, Equatable, Sendable {
    let type: String
    let loginId: String?
    let authUrl: String?
    let verificationUrl: String?
    let userCode: String?
}

struct CodexThreadSummary: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case idle
        case running
        case archived
        case failed
    }

    let id: String
    var title: String
    var cwd: String?
    var model: String?
    var createdAt: String?
    var status: Status
}

struct CodexThreadStartResponse: Decodable, Equatable, Sendable {
    let thread: CodexThread
    let model: String?
    let modelProvider: String?
    let cwd: String?
    let approvalPolicy: CodexApprovalPolicy?
    let sandbox: CodexSandboxMode?
    let reasoningEffort: String?
}

struct CodexThreadListResponse: Decodable, Equatable, Sendable {
    let threads: [CodexThread]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case data
        case threads
        case nextCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threads = try container.decodeIfPresent([CodexThread].self, forKey: .data)
            ?? container.decodeIfPresent([CodexThread].self, forKey: .threads)
            ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct CodexThreadResumeResponse: Decodable, Equatable, Sendable {
    let thread: CodexThread
}

struct CodexTurnStartResponse: Decodable, Equatable, Sendable {
    let turn: CodexTurn?
}

struct CodexThread: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let preview: String?
    let modelProvider: String?
    let createdAt: String?
    let updatedAt: String?
    let path: String?
    let cwd: String?
    let cliVersion: String?
    let source: String?
    let gitInfo: [String: AnyCodable]?
    let turns: [CodexTurn]?

    enum CodingKeys: String, CodingKey {
        case id, name, preview, modelProvider, createdAt, updatedAt, path, cwd, cliVersion, source, gitInfo, turns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        modelProvider = try container.decodeIfPresent(String.self, forKey: .modelProvider)
        createdAt = Self.decodeStringOrNumber(container, key: .createdAt)
        updatedAt = Self.decodeStringOrNumber(container, key: .updatedAt)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        cliVersion = try container.decodeIfPresent(String.self, forKey: .cliVersion)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        gitInfo = try container.decodeIfPresent([String: AnyCodable].self, forKey: .gitInfo)
        turns = try container.decodeIfPresent([CodexTurn].self, forKey: .turns)
    }

    var summary: CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            title: name?.nilIfBlank ?? preview?.nilIfBlank ?? "Codex Thread",
            cwd: cwd,
            model: modelProvider,
            createdAt: updatedAt ?? createdAt,
            status: .idle
        )
    }

    private static func decodeStringOrNumber(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> String? {
        if let string = try? container.decode(String.self, forKey: key) {
            return string
        }
        if let int = try? container.decode(Int.self, forKey: key) {
            return String(int)
        }
        if let double = try? container.decode(Double.self, forKey: key) {
            return String(double)
        }
        return nil
    }
}

struct CodexTurn: Decodable, Equatable, Sendable {
    let id: String
    let items: [CodexThreadItem]?
    let status: String?
    let error: CodexJSONRPCError?
}

enum CodexThreadItem: Decodable, Equatable, Sendable {
    case userMessage(id: String, content: [DecodedCodexUserInput])
    case agentMessage(id: String, text: String)
    case plan(id: String, text: String)
    case reasoning(id: String, summary: [String], content: [String])
    case commandExecution(id: String, command: String, cwd: String?, status: String, aggregatedOutput: String?, exitCode: Int?)
    case fileChange(id: String, status: String, changes: [String]?)
    case mcpToolCall(id: String, server: String?, tool: String?, status: String, error: String?)
    case webSearch(id: String, query: String?, status: String)
    case other(id: String, type: String, text: String?)

    enum CodingKeys: String, CodingKey {
        case id, type, content, text, summary, command, cwd, status, aggregatedOutput, exitCode
        case changes, server, tool, error, query, action, review
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        switch type {
        case "userMessage":
            self = .userMessage(
                id: id,
                content: try container.decodeIfPresent([DecodedCodexUserInput].self, forKey: .content) ?? []
            )
        case "agentMessage":
            self = .agentMessage(id: id, text: try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "plan":
            self = .plan(id: id, text: try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "reasoning":
            self = .reasoning(
                id: id,
                summary: try container.decodeIfPresent([String].self, forKey: .summary) ?? [],
                content: try container.decodeIfPresent([String].self, forKey: .content) ?? []
            )
        case "commandExecution":
            self = .commandExecution(
                id: id,
                command: try container.decodeIfPresent(String.self, forKey: .command) ?? "",
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                status: try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown",
                aggregatedOutput: try container.decodeIfPresent(String.self, forKey: .aggregatedOutput),
                exitCode: try container.decodeIfPresent(Int.self, forKey: .exitCode)
            )
        case "fileChange":
            self = .fileChange(
                id: id,
                status: try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown",
                changes: Self.decodeFileChangeSummaries(container)
            )
        case "mcpToolCall":
            self = .mcpToolCall(
                id: id,
                server: try container.decodeIfPresent(String.self, forKey: .server),
                tool: try container.decodeIfPresent(String.self, forKey: .tool),
                status: try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown",
                error: try container.decodeIfPresent(String.self, forKey: .error)
            )
        case "webSearch":
            let action = try container.decodeIfPresent([String: AnyCodable].self, forKey: .action)
            let status = try container.decodeIfPresent(String.self, forKey: .status)
            self = .webSearch(
                id: id,
                query: try container.decodeIfPresent(String.self, forKey: .query)
                    ?? action?["query"]?.stringValue
                    ?? action?["queries"]?.arrayValue?.compactMap { $0 as? String }.joined(separator: ", "),
                status: action?["type"]?.stringValue ?? status ?? "unknown"
            )
        default:
            let review = try container.decodeIfPresent(String.self, forKey: .review)
            self = .other(
                id: id,
                type: type,
                text: try container.decodeIfPresent(String.self, forKey: .text)
                    ?? review
            )
        }
    }

    private static func decodeFileChangeSummaries(_ container: KeyedDecodingContainer<CodingKeys>) -> [String]? {
        if let strings = try? container.decodeIfPresent([String].self, forKey: .changes) {
            return strings
        }

        guard let objects = try? container.decodeIfPresent([[String: AnyCodable]].self, forKey: .changes) else {
            return nil
        }

        return objects.map { change in
            let headline = [change["path"]?.stringValue, change["kind"]?.stringValue]
                .compactMap { $0?.nilIfBlank }
                .joined(separator: " ")
            return [headline.nilIfBlank, change["diff"]?.stringValue?.nilIfBlank]
                .compactMap { $0 }
                .joined(separator: "\n")
        }
    }
}

enum DecodedCodexUserInput: Decodable, Equatable, Sendable {
    case text(String)
    case imageURL(String)
    case localImage(path: String)
    case unknown

    enum CodingKeys: String, CodingKey {
        case type, text, url, path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image":
            self = .imageURL(try container.decodeIfPresent(String.self, forKey: .url) ?? "")
        case "localImage":
            self = .localImage(path: try container.decodeIfPresent(String.self, forKey: .path) ?? "")
        default:
            self = .unknown
        }
    }

    var textValue: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

struct CodexModelListResponse: Decodable, Equatable, Sendable {
    let data: [CodexModel]
    let nextCursor: String?
}

struct CodexModel: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let model: String?
    let displayName: String?
    let description: String?
    let supportedReasoningEfforts: [String]?
    let defaultReasoningEffort: String?
    let isDefault: Bool?
}

struct CodexAccountResponse: Decodable, Equatable, Sendable {
    let account: [String: AnyCodable]?
    let requiresOpenaiAuth: Bool?
}

struct CodexConfigReadResponse: Decodable, Equatable, Sendable {
    let config: [String: AnyCodable]
    let origins: [String: AnyCodable]?
    let layers: [String: AnyCodable]?
}

enum CodexApprovalKind: String, Codable, Equatable, Sendable {
    case command
    case fileChange
}

struct CodexApprovalRequest: Identifiable, Equatable, Sendable {
    let requestId: CodexJSONRPCID
    let kind: CodexApprovalKind
    let threadId: String
    let turnId: String
    let itemId: String
    let reason: String?

    var id: String { requestId.description }
}

enum CodexApprovalDecision: Equatable, Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
    case acceptWithExecPolicyAmendment([String])

    var payload: AnyCodable {
        switch self {
        case .accept: AnyCodable("accept")
        case .acceptForSession: AnyCodable("acceptForSession")
        case .decline: AnyCodable("decline")
        case .cancel: AnyCodable("cancel")
        case .acceptWithExecPolicyAmendment(let amendment):
            AnyCodable(["acceptWithExecpolicyAmendment": ["execpolicy_amendment": amendment]])
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
