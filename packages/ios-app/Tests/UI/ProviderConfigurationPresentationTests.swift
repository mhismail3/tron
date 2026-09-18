import Testing
@testable import TronMobile

@Suite("Provider configuration presentation")
struct ProviderConfigurationPresentationTests {
    @Test("waiting detail sheets allow dismissal while owned mutations remain modal")
    func interactiveDismissalPolicy() {
        #expect(!ProviderConfigurationPresentation.disablesInteractiveDismissal(beginningMethod: nil, clearing: false))
        #expect(ProviderConfigurationPresentation.disablesInteractiveDismissal(beginningMethod: "api-key", clearing: false))
        #expect(ProviderConfigurationPresentation.disablesInteractiveDismissal(beginningMethod: nil, clearing: true))
    }

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

    @Test("refresh keeps a compact visible circle and a full hit target")
    func refreshGeometryAndContrast() {
        #expect(ProviderUsageRefreshPresentation.visibleDiameter == 26)
        #expect(ProviderUsageRefreshPresentation.hitTargetDiameter == 44)
        #expect(ProviderUsageRefreshPresentation.iconPointSize == 13)
        #expect(TronSettingsButtonContrastPolicy.usesWhiteForeground(in: .dark))
        #expect(!TronSettingsButtonContrastPolicy.usesWhiteForeground(in: .light))
    }

    private func provider(configured: Bool, authMethods: [String]) -> ProviderSummary {
        ProviderSummary(
            id: "provider",
            name: "Provider",
            configured: configured,
            usageSupported: false,
            authSource: nil,
            credentialType: nil,
            authMethods: authMethods,
            modelCount: 1
        )
    }
}
