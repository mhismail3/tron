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
        endpoint = try? container.decodeIfPresent(String.self, forKey: .endpoint)
        projectId = try? container.decodeIfPresent(String.self, forKey: .projectId)
        hasClientId = try? container.decodeIfPresent(Bool.self, forKey: .hasClientId)
        hasClientSecret = try? container.decodeIfPresent(Bool.self, forKey: .hasClientSecret)
    }

    private enum CodingKeys: String, CodingKey {
        case hasApiKey, apiKeyHint, hasOAuth, oauthExpiresAt, isOAuthExpired
        case accounts, endpoint, projectId, hasClientId, hasClientSecret
    }
}

struct AccountInfo: Decodable {
    let label: String
    let expiresAt: Int64
    let isExpired: Bool
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
