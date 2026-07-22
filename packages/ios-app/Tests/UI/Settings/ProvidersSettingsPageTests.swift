import Testing
import Foundation
@testable import TronMobile

@Suite("Providers Page Tests")
struct ProvidersSettingsPageTests {
    private func providerInfo(json: String) throws -> ProviderAuthSnapshot {
        ProviderAuthSnapshot(try JSONDecoder().decode(ProviderAuthInfo.self, from: Data(json.utf8)))
    }

    @Test("provider settings copy matches current label")
    func providerSettingsCopyMatchesCurrentLabel() {
        #expect(SettingsLabels.providers == "Providers")
    }

    @Test("provider display helpers preserve server-provided provider IDs")
    func providerDisplayHelpersPreserveServerProviderIds() {
        #expect(ProviderInfo.displayName(for: "anthropic") == "Anthropic")
        #expect(ProviderInfo.displayName(for: "future-provider") == "future-provider")

        let knownOptions = ProviderInfo.settingsOptions(including: "google")
        #expect(knownOptions.map(\.value) == ["anthropic", "openai-codex", "google", "minimax", "kimi"])

        let unknownOptions = ProviderInfo.settingsOptions(including: "future-provider")
        #expect(unknownOptions.last?.value == "future-provider")
        #expect(unknownOptions.last?.label == "future-provider")
    }

    @Test("provider auth action result only commits local form changes after success")
    func providerAuthActionResultCommitsLocalFormChangesOnlyAfterSuccess() {
        #expect(ProviderAuthActionResult.succeeded.shouldCommitLocalFormChanges)
        #expect(!ProviderAuthActionResult.failed.shouldCommitLocalFormChanges)
    }

    @Test("credential row ids are stable and credential-type scoped")
    func credentialRowIdsAreStableAndCredentialTypeScoped() {
        let oauth = ProviderCredentialRowItem(kind: .oauth, label: "work")
        let apiKey = ProviderCredentialRowItem(kind: .apiKey, label: "work")

        #expect(oauth.id == "oauth:work")
        #expect(apiKey.id == "apiKey:work")
        #expect(oauth.id != apiKey.id)
    }

    @Test("modelProviders array contains the five expected providers")
    func providerArrayShape() {
        let ids = ProviderInfo.modelProviders.map(\.id)
        #expect(ids == ["anthropic", "openai-codex", "google", "minimax", "kimi"])
    }

    @Test("only Anthropic, OpenAI, and Google support OAuth")
    func oauthFlags() {
        let oauthIds = Set(ProviderInfo.modelProviders.filter(\.supportsOAuth).map(\.id))
        #expect(oauthIds == ["anthropic", "openai-codex", "google"])
    }

    @Test("MiniMax and Kimi do not support OAuth")
    func apiKeyOnlyProviders() {
        let apiKeyOnly = ProviderInfo.modelProviders.filter { !$0.supportsOAuth }.map(\.id)
        #expect(Set(apiKeyOnly) == ["minimax", "kimi"])
    }

    @Test("provider section containers exclude auth action buttons")
    func providerSectionContainersExcludeAuthActionButtons() {
        let anthropic = ProviderInfo.modelProviders.first { $0.id == "anthropic" }!
        let google = ProviderInfo.modelProviders.first { $0.id == "google" }!
        let minimax = ProviderInfo.modelProviders.first { $0.id == "minimax" }!

        #expect(ProviderSettingsContainer.containers(for: anthropic) == [.status])
        #expect(ProviderSettingsContainer.containers(for: google) == [.status, .googleCloud])
        #expect(ProviderSettingsContainer.containers(for: minimax) == [.status])
    }

    @Test("provider auth actions match OAuth tool")
    func providerAuthActionsMatchOAuthTool() {
        let anthropic = ProviderInfo.modelProviders.first { $0.id == "anthropic" }!
        let minimax = ProviderInfo.modelProviders.first { $0.id == "minimax" }!

        #expect(ProviderAuthActionItem.items(for: anthropic) == [.oauthLogin, .addApiKey])
        #expect(ProviderAuthActionItem.items(for: minimax) == [.addApiKey])
        #expect(ProviderAuthActionItem.oauthLogin.title == "OAuth Login")
        #expect(ProviderAuthActionItem.addApiKey.title == "Add API Key")
    }

    @Test("provider auth actions hide refreshable OAuth login")
    func providerAuthActionsHideRefreshableOAuthLogin() throws {
        let anthropic = ProviderInfo.modelProviders.first { $0.id == "anthropic" }!
        let minimax = ProviderInfo.modelProviders.first { $0.id == "minimax" }!
        let activeOAuth = try providerInfo(
            json: #"{"accounts":[{"label":"work","expiresAt":0,"isExpired":false,"hasRefreshToken":true}]}"#
        )
        let deadOAuth = try providerInfo(
            json: #"{"accounts":[{"label":"old","expiresAt":0,"isExpired":true,"hasRefreshToken":false}]}"#
        )

        #expect(ProviderAuthActionItem.visibleItems(for: anthropic, providerAuth: nil) == [.oauthLogin, .addApiKey])
        #expect(ProviderAuthActionItem.visibleItems(for: anthropic, providerAuth: activeOAuth) == [.addApiKey])
        #expect(ProviderAuthActionItem.visibleItems(for: anthropic, providerAuth: deadOAuth) == [.oauthLogin, .addApiKey])
        #expect(ProviderAuthActionItem.visibleItems(for: minimax, providerAuth: activeOAuth) == [.addApiKey])
    }

    @Test("provider auth action buttons are leading aligned")
    func providerAuthActionButtonsAreLeadingAligned() {
        #expect(ProviderAuthActionButtonsLayout.alignment == .leading)
    }

}
