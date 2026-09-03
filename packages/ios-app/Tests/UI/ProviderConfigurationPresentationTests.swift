import Testing
@testable import TronMobile

@Suite("Provider configuration presentation")
struct ProviderConfigurationPresentationTests {
    @Test("automatic setup starts only one supported unconfigured method")
    func automaticSingleMethod() {
        #expect(ProviderConfigurationPresentation.automaticallyBegunMethod(
            for: provider(configured: false, authMethods: ["oauth"])
        ) == "oauth")
        #expect(ProviderConfigurationPresentation.automaticallyBegunMethod(
            for: provider(configured: false, authMethods: ["api-key"])
        ) == "api-key")
        #expect(ProviderConfigurationPresentation.automaticallyBegunMethod(
            for: provider(configured: false, authMethods: ["api-key", "oauth"])
        ) == nil)
        #expect(ProviderConfigurationPresentation.automaticallyBegunMethod(
            for: provider(configured: true, authMethods: ["oauth"])
        ) == nil)
        #expect(ProviderConfigurationPresentation.automaticallyBegunMethod(
            for: provider(configured: false, authMethods: ["future-auth"])
        ) == nil)
    }

    private func provider(configured: Bool, authMethods: [String]) -> ProviderSummary {
        ProviderSummary(
            id: "provider",
            name: "Provider",
            configured: configured,
            authSource: nil,
            credentialType: nil,
            authMethods: authMethods,
            modelCount: 1
        )
    }
}
