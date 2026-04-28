import Testing
@testable import TronMobile

@Suite("Providers Page Tests")
struct ProvidersSettingsPageTests {

    @Test("provider settings copy matches current label")
    func providerSettingsCopyMatchesCurrentLabel() {
        #expect(SettingsLabels.providers == "Providers")
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

    @Test("services array contains Brave and Exa")
    func serviceArrayShape() {
        let ids = ProviderInfo.services.map(\.id)
        #expect(ids == ["brave", "exa"])
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

    @Test("service system icon dispatches by id")
    func serviceSystemIcons() {
        let brave = ProviderInfo.services.first { $0.id == "brave" }!
        let exa = ProviderInfo.services.first { $0.id == "exa" }!
        #expect(brave.serviceSystemIcon == "magnifyingglass")
        #expect(exa.serviceSystemIcon == "doc.text.magnifyingglass")
    }
}
