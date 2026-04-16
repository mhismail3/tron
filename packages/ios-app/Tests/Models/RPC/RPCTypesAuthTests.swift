import Testing
import Foundation
@testable import TronMobile

@Suite("Auth RPC Types Tests")
struct RPCTypesAuthTests {

    // MARK: - ProviderAuthInfo

    @Test("ProviderAuthInfo decode with all fields")
    func providerAuthFull() throws {
        let json = """
        {
            "hasApiKey": true,
            "apiKeyHint": "sk-ant-...xyz",
            "apiKeys": [{"label":"default","keyHint":"sk-ant-...xyz"}],
            "hasOAuth": true,
            "oauthExpiresAt": 1800000000,
            "isOAuthExpired": false,
            "accounts": [{"label":"work","expiresAt":1800000000,"isExpired":false,"hasRefreshToken":true}],
            "activeCredential": {"type":"oauth","label":"work"},
            "projectId": "proj-123"
        }
        """
        let info = try JSONDecoder().decode(ProviderAuthInfo.self, from: json.data(using: .utf8)!)
        #expect(info.hasApiKey == true)
        #expect(info.apiKeyHint == "sk-ant-...xyz")
        #expect(info.hasOAuth == true)
        #expect(info.oauthExpiresAt == 1800000000)
        #expect(info.isOAuthExpired == false)
        #expect(info.activeCredential?.label == "work")
        #expect(info.activeCredential?.isOAuth == true)
        #expect(info.accounts?.count == 1)
        #expect(info.apiKeys?.count == 1)
        #expect(info.projectId == "proj-123")
    }

    @Test("ProviderAuthInfo decode with missing optional fields uses defaults")
    func providerAuthDefaults() throws {
        let json = "{}"
        let info = try JSONDecoder().decode(ProviderAuthInfo.self, from: json.data(using: .utf8)!)
        #expect(info.hasApiKey == false)
        #expect(info.hasOAuth == false)
        #expect(info.apiKeyHint == nil)
        #expect(info.accounts == nil)
        #expect(info.apiKeys == nil)
        #expect(info.activeCredential == nil)
        #expect(info.projectId == nil)
    }

    // MARK: - AccountInfo

    @Test("AccountInfo decode with all fields")
    func accountInfoFull() throws {
        let json = #"{"label":"personal","expiresAt":1800000000,"isExpired":false,"hasRefreshToken":true}"#
        let info = try JSONDecoder().decode(AccountInfo.self, from: json.data(using: .utf8)!)
        #expect(info.label == "personal")
        #expect(info.expiresAt == 1800000000)
        #expect(info.isExpired == false)
        #expect(info.hasRefreshToken == true)
    }

    @Test("AccountInfo decode with missing hasRefreshToken defaults to false")
    func accountInfoDefaultRefreshToken() throws {
        let json = #"{"label":"test","expiresAt":0,"isExpired":true}"#
        let info = try JSONDecoder().decode(AccountInfo.self, from: json.data(using: .utf8)!)
        #expect(info.hasRefreshToken == false)
    }

    // MARK: - ServiceAuthInfo

    @Test("ServiceAuthInfo decode with missing hasApiKey defaults to false")
    func serviceAuthDefaults() throws {
        let json = "{}"
        let info = try JSONDecoder().decode(ServiceAuthInfo.self, from: json.data(using: .utf8)!)
        #expect(info.hasApiKey == false)
        #expect(info.apiKeyHint == nil)
    }

    @Test("ServiceAuthInfo decode with fields present")
    func serviceAuthFull() throws {
        let json = #"{"hasApiKey":true,"apiKeyHint":"sk-...abc"}"#
        let info = try JSONDecoder().decode(ServiceAuthInfo.self, from: json.data(using: .utf8)!)
        #expect(info.hasApiKey == true)
        #expect(info.apiKeyHint == "sk-...abc")
    }

    // MARK: - ActiveCredentialInfo

    @Test("ActiveCredentialInfo oauth type")
    func activeCredentialOAuth() throws {
        let json = #"{"type":"oauth","label":"work"}"#
        let info = try JSONDecoder().decode(ActiveCredentialInfo.self, from: json.data(using: .utf8)!)
        #expect(info.isOAuth == true)
        #expect(info.isApiKey == false)
    }

    @Test("ActiveCredentialInfo apiKey type")
    func activeCredentialApiKey() throws {
        let json = #"{"type":"apiKey","label":"default"}"#
        let info = try JSONDecoder().decode(ActiveCredentialInfo.self, from: json.data(using: .utf8)!)
        #expect(info.isApiKey == true)
        #expect(info.isOAuth == false)
    }

    // MARK: - AnyCodableOptional

    @Test("AnyCodableOptional value encodes to string")
    func anyCodableOptionalValue() throws {
        let opt = AnyCodableOptional.value("test-key")
        let data = try JSONEncoder().encode(opt)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "\"test-key\"")
    }

    @Test("AnyCodableOptional null encodes to null")
    func anyCodableOptionalNull() throws {
        let opt = AnyCodableOptional.null
        let data = try JSONEncoder().encode(opt)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "null")
    }

    // MARK: - AuthState

    @Test("AuthState decode with providers and services")
    func authStateDecode() throws {
        let json = """
        {
            "providers": {
                "anthropic": {"hasApiKey":true,"hasOAuth":false}
            },
            "services": {
                "github": {"hasApiKey":false}
            }
        }
        """
        let state = try JSONDecoder().decode(AuthState.self, from: json.data(using: .utf8)!)
        #expect(state.providers["anthropic"]?.hasApiKey == true)
        #expect(state.services["github"]?.hasApiKey == false)
    }

    // MARK: - ApiKeyInfo

    @Test("ApiKeyInfo decode")
    func apiKeyInfo() throws {
        let json = #"{"label":"prod","keyHint":"sk-...xyz"}"#
        let info = try JSONDecoder().decode(ApiKeyInfo.self, from: json.data(using: .utf8)!)
        #expect(info.label == "prod")
        #expect(info.keyHint == "sk-...xyz")
    }
}
