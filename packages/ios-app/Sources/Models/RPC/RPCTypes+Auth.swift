import Foundation

// MARK: - Auth State (Response from auth.get / auth.update / auth.clear)

struct AuthState: Decodable {
    let providers: [String: ProviderAuthInfo]
    let services: [String: ServiceAuthInfo]
}

struct ProviderAuthInfo: Decodable {
    let hasApiKey: Bool
    let apiKeyHint: String?
    let hasOAuth: Bool
    let oauthExpiresAt: Int64?
    let isOAuthExpired: Bool?
    let accounts: [AccountInfo]?

    // Multi-credential fields
    let apiKeys: [ApiKeyInfo]?
    let activeCredential: ActiveCredentialInfo?

    // Google-specific fields
    let endpoint: String?
    let projectId: String?
    let hasClientId: Bool?
    let hasClientSecret: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasApiKey = (try? container.decode(Bool.self, forKey: .hasApiKey)) ?? false
        apiKeyHint = try? container.decodeIfPresent(String.self, forKey: .apiKeyHint)
        hasOAuth = (try? container.decode(Bool.self, forKey: .hasOAuth)) ?? false
        oauthExpiresAt = try? container.decodeIfPresent(Int64.self, forKey: .oauthExpiresAt)
        isOAuthExpired = try? container.decodeIfPresent(Bool.self, forKey: .isOAuthExpired)
        accounts = try? container.decodeIfPresent([AccountInfo].self, forKey: .accounts)
        apiKeys = try? container.decodeIfPresent([ApiKeyInfo].self, forKey: .apiKeys)
        activeCredential = try? container.decodeIfPresent(ActiveCredentialInfo.self, forKey: .activeCredential)
        endpoint = try? container.decodeIfPresent(String.self, forKey: .endpoint)
        projectId = try? container.decodeIfPresent(String.self, forKey: .projectId)
        hasClientId = try? container.decodeIfPresent(Bool.self, forKey: .hasClientId)
        hasClientSecret = try? container.decodeIfPresent(Bool.self, forKey: .hasClientSecret)
    }

    private enum CodingKeys: String, CodingKey {
        case hasApiKey, apiKeyHint, hasOAuth, oauthExpiresAt, isOAuthExpired
        case accounts, apiKeys, activeCredential
        case endpoint, projectId, hasClientId, hasClientSecret
    }
}

struct AccountInfo: Decodable {
    let label: String
    let expiresAt: Int64
    let isExpired: Bool
    let hasRefreshToken: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        expiresAt = try container.decode(Int64.self, forKey: .expiresAt)
        isExpired = try container.decode(Bool.self, forKey: .isExpired)
        hasRefreshToken = (try? container.decode(Bool.self, forKey: .hasRefreshToken)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case label, expiresAt, isExpired, hasRefreshToken
    }
}

struct ServiceAuthInfo: Decodable {
    let hasApiKey: Bool
    let apiKeyHint: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasApiKey = (try? container.decode(Bool.self, forKey: .hasApiKey)) ?? false
        apiKeyHint = try? container.decodeIfPresent(String.self, forKey: .apiKeyHint)
    }

    private enum CodingKeys: String, CodingKey {
        case hasApiKey, apiKeyHint
    }
}

// MARK: - Auth Update Params (Encodable)

struct AuthUpdateParams: Encodable {
    var provider: String?
    var service: String?
    var apiKey: AnyCodableOptional?

    // OAuth fields (for provider updates)
    var oauth: OAuthInput?

    // Google-specific fields
    var clientId: String?
    var clientSecret: String?
    var endpoint: String?
    var projectId: String?
}

/// Wrapper to encode a string value or null (for clearing).
enum AnyCodableOptional: Encodable {
    case value(String)
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .value(let str):
            try container.encode(str)
        case .null:
            try container.encodeNil()
        }
    }
}

struct OAuthInput: Encodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
}

// MARK: - Auth Clear Params (Encodable)

struct AuthClearParams: Encodable {
    var provider: String?
    var service: String?
}

// MARK: - OAuth Flow Types

struct OAuthBeginParams: Encodable {
    let provider: String
}

struct OAuthBeginResponse: Decodable {
    let flowId: String
    let authUrl: String
}

struct OAuthCompleteParams: Encodable {
    let flowId: String
    let code: String
    let label: String
}

struct RenameAccountParams: Encodable {
    let provider: String
    let oldLabel: String
    let newLabel: String
}

// MARK: - Named API Key Info (Response)

struct ApiKeyInfo: Decodable {
    let label: String
    let keyHint: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        keyHint = try container.decode(String.self, forKey: .keyHint)
    }

    private enum CodingKeys: String, CodingKey {
        case label, keyHint
    }
}

// MARK: - Active Credential Info (Response)

struct ActiveCredentialInfo: Decodable, Equatable {
    let type: String   // "oauth" or "apiKey"
    let label: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        label = try container.decode(String.self, forKey: .label)
    }

    private enum CodingKeys: String, CodingKey {
        case type, label
    }

    var isOAuth: Bool { type == "oauth" }
    var isApiKey: Bool { type == "apiKey" }
}

// MARK: - Set Active Credential Params

struct SetActiveParams: Encodable {
    let provider: String
    let credential: ActiveCredentialParam
}

struct ActiveCredentialParam: Encodable {
    let type: String
    let label: String
}

// MARK: - Remove Account/Key Params

struct RemoveAccountParams: Encodable {
    let provider: String
    let label: String
}

struct RemoveApiKeyParams: Encodable {
    let provider: String
    let label: String
}

// MARK: - Add Named API Key Params

struct AddNamedApiKeyParams: Encodable {
    let provider: String
    let apiKey: String
    let apiKeyLabel: String
}
