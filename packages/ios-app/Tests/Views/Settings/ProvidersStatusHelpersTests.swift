import Testing
import Foundation
import SwiftUI

@testable import TronMobile

@Suite("ProviderStatusHelpers Tests")
struct ProviderStatusHelpersTests {

    private func account(
        label: String = "work",
        isExpired: Bool = false,
        hasRefreshToken: Bool = true
    ) throws -> AccountInfo {
        let json = #"{"label":"\#(label)","expiresAt":0,"isExpired":\#(isExpired),"hasRefreshToken":\#(hasRefreshToken)}"#
        return try JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
    }

    private func providerInfo(json: String) throws -> ProviderAuthInfo {
        try JSONDecoder().decode(ProviderAuthInfo.self, from: Data(json.utf8))
    }

    // MARK: - accountStatus

    @Test("accountStatus returns Active for fresh account")
    func accountStatusFresh() throws {
        let a = try account(isExpired: false, hasRefreshToken: false)
        #expect(ProviderStatusHelpers.accountStatus(a) == "Active")
    }

    @Test("accountStatus returns Will refresh for expired with refresh token")
    func accountStatusWillRefresh() throws {
        let a = try account(isExpired: true, hasRefreshToken: true)
        #expect(ProviderStatusHelpers.accountStatus(a) == "Will refresh")
    }

    @Test("accountStatus returns Expired for expired without refresh token")
    func accountStatusExpired() throws {
        let a = try account(isExpired: true, hasRefreshToken: false)
        #expect(ProviderStatusHelpers.accountStatus(a) == "Expired")
    }

    // MARK: - accountStatusColor

    @Test("accountStatusColor returns tronSuccess for fresh")
    func accountStatusColorFresh() throws {
        let a = try account(isExpired: false)
        #expect(ProviderStatusHelpers.accountStatusColor(a) == Color.tronSuccess)
    }

    @Test("accountStatusColor returns tronAmber for expired with refresh")
    func accountStatusColorRefreshing() throws {
        let a = try account(isExpired: true, hasRefreshToken: true)
        #expect(ProviderStatusHelpers.accountStatusColor(a) == Color.tronAmber)
    }

    @Test("accountStatusColor returns tronError for expired without refresh")
    func accountStatusColorExpired() throws {
        let a = try account(isExpired: true, hasRefreshToken: false)
        #expect(ProviderStatusHelpers.accountStatusColor(a) == Color.tronError)
    }

    // MARK: - accountDetail

    @Test("accountDetail describes fresh OAuth account")
    func accountDetailFresh() throws {
        let a = try account(isExpired: false)
        #expect(ProviderStatusHelpers.accountDetail(a) == "Logged in with OAuth")
    }

    @Test("accountDetail describes refreshable expired OAuth account")
    func accountDetailRefreshing() throws {
        let a = try account(isExpired: true, hasRefreshToken: true)
        #expect(ProviderStatusHelpers.accountDetail(a) == "OAuth will refresh")
    }

    @Test("accountDetail describes expired OAuth account without refresh")
    func accountDetailExpired() throws {
        let a = try account(isExpired: true, hasRefreshToken: false)
        #expect(ProviderStatusHelpers.accountDetail(a) == "OAuth expired")
    }

    @Test("credential status rows use explicit clear action copy")
    func credentialStatusRowsUseExplicitClearActionCopy() {
        #expect(ProviderCredentialStatusAction.title == "Clear")
        #expect(ProviderCredentialStatusAction.confirmationTitle == "Clear credential?")
        #expect(ProviderCredentialStatusAction.confirmationButtonTitle == "Clear")
    }

    @Test("credential clear action uses compact pill styling")
    func credentialClearActionUsesCompactPillStyling() {
        #expect(ProviderCredentialClearPillStyle.fontSize == TronTypography.sizeSM)
        #expect(ProviderCredentialClearPillStyle.horizontalPadding == 8)
        #expect(ProviderCredentialClearPillStyle.verticalPadding == 4)
        #expect(ProviderCredentialClearPillStyle.backgroundOpacity == 0.12)
    }

    @Test("API key prompt uses native alert presentation")
    func apiKeyPromptUsesNativeAlertPresentation() {
        #expect(ProviderApiKeyPrompt.presentation == .nativeAlert)
        #expect(ProviderApiKeyPrompt.labelPlaceholder == "Label")
        #expect(ProviderApiKeyPrompt.keyPlaceholder == "API Key")
        #expect(ProviderApiKeyPrompt.cancelButtonTitle == "Cancel")
        #expect(ProviderApiKeyPrompt.saveButtonTitle == "Save")
    }

    @Test("API key prompt scopes require labels only for model providers")
    func apiKeyPromptScopesRequireLabelsOnlyForModelProviders() {
        let providerScope = ProviderApiKeyPromptScope.provider(id: "anthropic", displayName: "Anthropic")
        let serviceScope = ProviderApiKeyPromptScope.service(id: "brave", displayName: "Brave Search")

        #expect(providerScope.title == "Add Anthropic API Key")
        #expect(providerScope.showsLabelField)
        #expect(serviceScope.title == "Add Brave Search API Key")
        #expect(!serviceScope.showsLabelField)
    }

    @Test("API key prompt drafts validate trimmed provider labels and service keys")
    func apiKeyPromptDraftsValidateByScope() {
        let providerScope = ProviderApiKeyPromptScope.provider(id: "anthropic", displayName: "Anthropic")
        let serviceScope = ProviderApiKeyPromptScope.service(id: "brave", displayName: "Brave Search")

        #expect(!ProviderApiKeyPromptDraft(label: "  ", apiKey: "sk-test").isValid(for: providerScope))
        #expect(!ProviderApiKeyPromptDraft(label: "work", apiKey: "").isValid(for: providerScope))
        #expect(ProviderApiKeyPromptDraft(label: " work ", apiKey: "sk-test").isValid(for: providerScope))
        #expect(ProviderApiKeyPromptDraft(label: "", apiKey: "BSA0-test").isValid(for: serviceScope))
        #expect(ProviderApiKeyPromptDraft(label: "ignored", apiKey: "BSA0-test").saveLabel(for: serviceScope) == "")
        #expect(ProviderApiKeyPromptDraft(label: " work ", apiKey: "sk-test").saveLabel(for: providerScope) == "work")
    }

    // MARK: - isProviderConfigured

    @Test("isProviderConfigured returns false for nil")
    func isProviderConfiguredNil() {
        #expect(ProviderStatusHelpers.isProviderConfigured(nil) == false)
    }

    @Test("isProviderConfigured returns true when hasApiKey")
    func isProviderConfiguredHasApiKey() throws {
        let info = try providerInfo(json: #"{"hasApiKey":true,"hasOAuth":false}"#)
        #expect(ProviderStatusHelpers.isProviderConfigured(info) == true)
    }

    @Test("isProviderConfigured returns true when hasOAuth")
    func isProviderConfiguredHasOAuth() throws {
        let info = try providerInfo(json: #"{"hasApiKey":false,"hasOAuth":true}"#)
        #expect(ProviderStatusHelpers.isProviderConfigured(info) == true)
    }

    @Test("isProviderConfigured returns true when accounts non-empty")
    func isProviderConfiguredAccounts() throws {
        let info = try providerInfo(json: #"{"hasApiKey":false,"hasOAuth":false,"accounts":[{"label":"a","expiresAt":0,"isExpired":false}]}"#)
        #expect(ProviderStatusHelpers.isProviderConfigured(info) == true)
    }

    @Test("isProviderConfigured returns true when apiKeys non-empty")
    func isProviderConfiguredApiKeys() throws {
        let info = try providerInfo(json: #"{"hasApiKey":false,"hasOAuth":false,"apiKeys":[{"label":"a","keyHint":"sk-...x"}]}"#)
        #expect(ProviderStatusHelpers.isProviderConfigured(info) == true)
    }

    @Test("isProviderConfigured returns false when empty arrays and both flags false")
    func isProviderConfiguredEmpty() throws {
        let info = try providerInfo(json: #"{"hasApiKey":false,"hasOAuth":false,"accounts":[],"apiKeys":[]}"#)
        #expect(ProviderStatusHelpers.isProviderConfigured(info) == false)
    }

    // MARK: - isAccountActive

    @Test("isAccountActive returns false for nil info")
    func isAccountActiveNil() {
        #expect(ProviderStatusHelpers.isAccountActive(nil, label: "work") == false)
    }

    @Test("isAccountActive true when label matches and type is oauth")
    func isAccountActiveMatch() throws {
        let info = try providerInfo(json: #"{"activeCredential":{"type":"oauth","label":"work"}}"#)
        #expect(ProviderStatusHelpers.isAccountActive(info, label: "work") == true)
    }

    @Test("isAccountActive false when label matches but type is apiKey")
    func isAccountActiveWrongType() throws {
        let info = try providerInfo(json: #"{"activeCredential":{"type":"apiKey","label":"work"}}"#)
        #expect(ProviderStatusHelpers.isAccountActive(info, label: "work") == false)
    }

    @Test("isAccountActive false when label mismatches")
    func isAccountActiveLabelMismatch() throws {
        let info = try providerInfo(json: #"{"activeCredential":{"type":"oauth","label":"personal"}}"#)
        #expect(ProviderStatusHelpers.isAccountActive(info, label: "work") == false)
    }

    // MARK: - isApiKeyActive

    @Test("isApiKeyActive true when label matches and type is apiKey")
    func isApiKeyActiveMatch() throws {
        let info = try providerInfo(json: #"{"activeCredential":{"type":"apiKey","label":"prod"}}"#)
        #expect(ProviderStatusHelpers.isApiKeyActive(info, label: "prod") == true)
    }

    @Test("isApiKeyActive false when label matches but type is oauth")
    func isApiKeyActiveWrongType() throws {
        let info = try providerInfo(json: #"{"activeCredential":{"type":"oauth","label":"prod"}}"#)
        #expect(ProviderStatusHelpers.isApiKeyActive(info, label: "prod") == false)
    }

    // MARK: - hasRefreshableOAuth

    @Test("hasRefreshableOAuth false when no accounts")
    func hasRefreshableOAuthNone() throws {
        let info = try providerInfo(json: #"{"accounts":[]}"#)
        #expect(ProviderStatusHelpers.hasRefreshableOAuth(info) == false)
    }

    @Test("hasRefreshableOAuth true when one account not expired")
    func hasRefreshableOAuthActive() throws {
        let info = try providerInfo(json: #"{"accounts":[{"label":"a","expiresAt":0,"isExpired":false}]}"#)
        #expect(ProviderStatusHelpers.hasRefreshableOAuth(info) == true)
    }

    @Test("hasRefreshableOAuth true when all expired but one has refresh token")
    func hasRefreshableOAuthRefresh() throws {
        let json = #"{"accounts":[{"label":"a","expiresAt":0,"isExpired":true,"hasRefreshToken":false},{"label":"b","expiresAt":0,"isExpired":true,"hasRefreshToken":true}]}"#
        let info = try providerInfo(json: json)
        #expect(ProviderStatusHelpers.hasRefreshableOAuth(info) == true)
    }

    @Test("hasRefreshableOAuth false when all expired and none have refresh token")
    func hasRefreshableOAuthAllDead() throws {
        let json = #"{"accounts":[{"label":"a","expiresAt":0,"isExpired":true,"hasRefreshToken":false}]}"#
        let info = try providerInfo(json: json)
        #expect(ProviderStatusHelpers.hasRefreshableOAuth(info) == false)
    }

    // MARK: - isServiceConfigured

    @Test("isServiceConfigured reflects service API key state")
    func isServiceConfiguredReflectsApiKeyState() throws {
        let configured = try JSONDecoder().decode(ServiceAuthInfo.self, from: Data(#"{"hasApiKey":true,"apiKeyHint":"BSA0...abc"}"#.utf8))
        let empty = try JSONDecoder().decode(ServiceAuthInfo.self, from: Data(#"{"hasApiKey":false}"#.utf8))

        #expect(ProviderStatusHelpers.isServiceConfigured(configured))
        #expect(!ProviderStatusHelpers.isServiceConfigured(empty))
        #expect(!ProviderStatusHelpers.isServiceConfigured(nil))
    }

    // MARK: - trimmedLabel

    @Test("trimmedLabel strips surrounding whitespace")
    func trimmedLabelStripsSurrounding() {
        #expect(ProviderStatusHelpers.trimmedLabel("  work  ") == "work")
    }

    @Test("trimmedLabel preserves inner whitespace")
    func trimmedLabelPreservesInner() {
        #expect(ProviderStatusHelpers.trimmedLabel("my key") == "my key")
    }
}
