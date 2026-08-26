import Testing
@testable import TronMobile

@Suite("Provider configuration presentation")
struct ProviderConfigurationPresentationTests {
    @Test("credential methods use direct connection and replacement labels")
    func credentialLabels() {
        #expect(ProviderConfigurationPresentation.actionTitle(method: "api-key", configured: false) == "Enter API Key")
        #expect(ProviderConfigurationPresentation.actionTitle(method: "api-key", configured: true) == "Enter a New API Key")
        #expect(!ProviderConfigurationPresentation.isLoginMethod("api-key"))
    }

    @Test("login methods use account-specific connection and replacement labels")
    func loginLabels() {
        #expect(ProviderConfigurationPresentation.isLoginMethod("oauth"))
        #expect(ProviderConfigurationPresentation.isLoginMethod("device-code"))
        #expect(ProviderConfigurationPresentation.actionTitle(method: "oauth", configured: false) == "Log In")
        #expect(ProviderConfigurationPresentation.actionTitle(method: "oauth", configured: true) == "Log In with a Different Account")
    }

    @Test("clear actions and connection summaries match credential authority")
    func statusLabels() {
        let login = provider(configured: true, authSource: "oauth")
        let credential = provider(configured: true, authSource: "stored_credential")
        let credentialTypedLogin = provider(configured: true, authSource: nil, credentialType: "oauth")
        let empty = provider(configured: false, authSource: nil)

        #expect(ProviderConfigurationPresentation.clearTitle(for: login) == "Clear Login Information")
        #expect(ProviderConfigurationPresentation.clearTitle(for: credentialTypedLogin) == "Clear Login Information")
        #expect(ProviderConfigurationPresentation.clearTitle(for: credential) == "Clear API Key")
        #expect(ProviderConfigurationPresentation.connectionDetail(for: login) == "Connected - OAuth")
        #expect(ProviderConfigurationPresentation.connectionDetail(for: credential) == "Connected - stored credential")
        #expect(ProviderConfigurationPresentation.connectionDetail(for: empty) == "Not configured")
        #expect(ProviderConfigurationPresentation.configurationDetail(for: login) == "OAuth")
        #expect(ProviderConfigurationPresentation.configurationDetail(for: credential) == "Stored credential")
        #expect(ProviderConfigurationPresentation.configurationDetail(for: empty) == "Choose a connection method below.")
    }

    private func provider(
        configured: Bool,
        authSource: String?,
        credentialType: String? = nil
    ) -> ProviderSummary {
        ProviderSummary(
            id: "provider",
            name: "Provider",
            configured: configured,
            authSource: authSource,
            credentialType: credentialType,
            authMethods: ["api-key", "oauth"],
            modelCount: 1
        )
    }
}
