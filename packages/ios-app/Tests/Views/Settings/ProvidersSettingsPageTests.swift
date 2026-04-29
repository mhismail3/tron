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

    @Test("services section header is a stronger boundary than provider headers")
    func servicesSectionHeaderIsStrongerBoundaryThanProviderHeaders() {
        #expect(ProvidersServicesSectionHeaderStyle.fontSize > TronTypography.sizeBodySM)
        #expect(ProvidersServicesSectionHeaderStyle.topPadding > ProvidersServicesSectionHeaderStyle.bottomPadding)
        #expect(ProvidersServicesSectionHeaderStyle.bottomPadding < 8)
    }

    @Test("providers summary describes unloaded empty and configured states")
    func providersSummaryDescribesCredentialState() {
        let unloaded = ProvidersSettingsSummary.Context(
            isLoaded: false,
            configuredModelProviderCount: 0,
            totalModelProviderCount: 5,
            configuredServiceCount: 0,
            totalServiceCount: 2
        )
        #expect(ProvidersSettingsSummary.title(for: unloaded) == "Load credential status")
        #expect(ProvidersSettingsSummary.description(for: unloaded) == "Loading provider and service credential status from the active server.")

        let empty = ProvidersSettingsSummary.Context(
            isLoaded: true,
            configuredModelProviderCount: 0,
            totalModelProviderCount: 5,
            configuredServiceCount: 0,
            totalServiceCount: 2
        )
        #expect(ProvidersSettingsSummary.title(for: empty) == "Connect providers")
        #expect(ProvidersSettingsSummary.description(for: empty) == "No model providers or services are configured. Add OAuth accounts or API keys; secrets stay on the Mac server.")

        let configured = ProvidersSettingsSummary.Context(
            isLoaded: true,
            configuredModelProviderCount: 3,
            totalModelProviderCount: 5,
            configuredServiceCount: 1,
            totalServiceCount: 2
        )
        #expect(ProvidersSettingsSummary.title(for: configured) == "4 connections ready")
        #expect(ProvidersSettingsSummary.description(for: configured) == "3 model providers and 1 service are configured. Secrets stay on the Mac server.")

        let allConfigured = ProvidersSettingsSummary.Context(
            isLoaded: true,
            configuredModelProviderCount: 5,
            totalModelProviderCount: 5,
            configuredServiceCount: 2,
            totalServiceCount: 2
        )
        #expect(ProvidersSettingsSummary.title(for: allConfigured) == "7 connections ready")
        #expect(ProvidersSettingsSummary.description(for: allConfigured) == "All 5 model providers and all 2 services are configured. Secrets stay on the Mac server.")
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

    @Test("provider section containers exclude auth action buttons")
    func providerSectionContainersExcludeAuthActionButtons() {
        let anthropic = ProviderInfo.modelProviders.first { $0.id == "anthropic" }!
        let google = ProviderInfo.modelProviders.first { $0.id == "google" }!
        let minimax = ProviderInfo.modelProviders.first { $0.id == "minimax" }!

        #expect(ProviderSettingsContainer.containers(for: anthropic) == [.status])
        #expect(ProviderSettingsContainer.containers(for: google) == [.status, .googleCloud])
        #expect(ProviderSettingsContainer.containers(for: minimax) == [.status])
    }

    @Test("provider auth actions match OAuth capability")
    func providerAuthActionsMatchOAuthCapability() {
        let anthropic = ProviderInfo.modelProviders.first { $0.id == "anthropic" }!
        let minimax = ProviderInfo.modelProviders.first { $0.id == "minimax" }!

        #expect(ProviderAuthActionItem.items(for: anthropic) == [.oauthLogin, .addApiKey])
        #expect(ProviderAuthActionItem.items(for: minimax) == [.addApiKey])
        #expect(ProviderAuthActionItem.oauthLogin.title == "OAuth Login")
        #expect(ProviderAuthActionItem.addApiKey.title == "Add API Key")
    }

    @Test("provider auth action buttons are leading aligned")
    func providerAuthActionButtonsAreLeadingAligned() {
        #expect(ProviderAuthActionButtonsLayout.alignment == .leading)
    }

    @Test("service system icon dispatches by id")
    func serviceSystemIcons() {
        let brave = ProviderInfo.services.first { $0.id == "brave" }!
        let exa = ProviderInfo.services.first { $0.id == "exa" }!
        #expect(brave.serviceSystemIcon == "magnifyingglass")
        #expect(exa.serviceSystemIcon == "doc.text.magnifyingglass")
    }
}
