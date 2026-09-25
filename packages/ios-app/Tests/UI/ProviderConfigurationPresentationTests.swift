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

    @Test("changing an answered choice keeps earlier answers and replays them in order")
    func selectionTrailReplay() {
        let method = select("method", "Select method:", ["token", "profile", "chain"])
        let region = select("region", "Select region:", ["us", "eu"])
        var trail = ProviderAuthSelectionTrail()
        trail.record(method, chosenID: "token")
        trail.record(region, chosenID: "us")
        trail.record(text("secret"), chosenID: "ignored")
        #expect(trail.steps.map(\.chosenID) == ["token", "us"])

        // Unknown or unchanged answers do not restart anything.
        trail.change(stepAt: 0, to: "token")
        trail.change(stepAt: 0, to: "missing")
        #expect(!trail.isReplaying)

        trail.change(stepAt: 0, to: "profile")
        #expect(trail.isReplaying)
        #expect(trail.steps.map(\.chosenID) == ["profile"], "later answers depend on the changed one")
        let successor = select("method-2", "Select method:", ["token", "profile", "chain"])
        #expect(trail.replayAnswer(for: successor) == "profile")
        #expect(trail.consumeReplay(for: successor) == "profile")
        #expect(!trail.isReplaying)
        #expect(trail.steps.map(\.chosenID) == ["profile"])
    }

    @Test("a successor prompt that no longer matches ends the replay")
    func selectionTrailMismatch() {
        var trail = ProviderAuthSelectionTrail()
        trail.record(select("a", "Select method:", ["x", "y"]), chosenID: "x")
        trail.change(stepAt: 0, to: "y")
        let changedOptions = select("b", "Select method:", ["x", "y", "z"])
        #expect(trail.replayAnswer(for: changedOptions) == nil)
        #expect(trail.consumeReplay(for: changedOptions) == nil)
        #expect(!trail.isReplaying)
        #expect(trail.steps.isEmpty, "an answer the successor did not confirm is not shown as chosen")
        #expect(ProviderAuthFlowContent.title("Select Amazon Bedrock authentication method:")
            == "Select Amazon Bedrock authentication method")
    }

    private func select(_ id: String, _ message: String, _ options: [String]) -> ProviderAuthPromptState {
        ProviderAuthPromptState(id: id, operationId: "operation", kind: .select, message: message, placeholder: nil,
            options: options.map { .init(id: $0, label: $0, description: nil) })
    }

    private func text(_ id: String) -> ProviderAuthPromptState {
        ProviderAuthPromptState(id: id, operationId: "operation", kind: .secret, message: "Enter token", placeholder: nil, options: [])
    }

    private func provider(configured: Bool, authMethods: [String]) -> ProviderSummary {
        ProviderSummary(
            id: "provider",
            name: "Provider",
            configured: configured,
            usageSupported: false, localOnly: nil,
            authSource: nil,
            credentialType: nil,
            authMethods: authMethods,
            modelCount: 1
        )
    }
}
