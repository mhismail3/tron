import Testing

@testable import TronMobile

@Suite("Providers Page Tests")
struct ProvidersSettingsPageTests {

    @Test("settings copy matches current labels")
    func settingsCopyMatchesCurrentLabels() {
        #expect(SettingsLabels.providers == "Providers")
        #expect(SettingsLabels.connectToNewServer == "Connect to a new server")
        #expect(SettingsLabels.transcriptionSidecar == "Transcription Sidecar")
    }

    @Test("server-backed settings show transcription before security")
    func serverBackedSettingsOrder() {
        #expect(ConnectionSettingsServerBackedSection.loadedOrder == [
            .transcriptionSidecar,
            .advancedSecurity,
        ])
        #expect(ConnectionSettingsServerBackedSection.transcriptionSidecar.title == "Transcription Sidecar")
        #expect(ConnectionSettingsServerBackedSection.advancedSecurity.title == "Advanced Security")
    }

    @Test("server onboarding userInfo carries paired server id")
    func serverOnboardingUserInfoCarriesServerId() {
        #expect(ServerOnboardingLauncher.userInfo(serverId: "studio") == [
            ServerOnboardingLauncher.serverIdUserInfoKey: "studio",
        ])
        #expect(ServerOnboardingLauncher.userInfo(serverId: nil).isEmpty)
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
