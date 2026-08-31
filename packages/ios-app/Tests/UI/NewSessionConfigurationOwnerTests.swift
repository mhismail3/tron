import Testing
@testable import TronMobile

@Suite("New session configuration ownership")
struct NewSessionConfigurationOwnerTests {
    @Test("workspace and profile changes close creation until matching loads finish")
    func configurationAdmission() {
        let initialLoad = NewSessionConfigurationLoadID(
            profileID: "profile-a",
            workspace: "/workspace/a",
            trustInvalidationGeneration: 0
        )
        #expect(initialLoad != NewSessionConfigurationLoadID(
            profileID: "profile-a",
            workspace: "/workspace/a",
            trustInvalidationGeneration: 1
        ))
        #expect(initialLoad != NewSessionConfigurationLoadID(
            profileID: "profile-a",
            workspace: "/workspace/b",
            trustInvalidationGeneration: 0
        ))
        #expect(initialLoad != NewSessionConfigurationLoadID(
            profileID: "profile-b",
            workspace: "/workspace/a",
            trustInvalidationGeneration: 0
        ))
        #expect(initialLoad != NewSessionConfigurationLoadID(
            profileID: "profile-a",
            workspace: "/workspace/a",
            trustInvalidationGeneration: 0,
            profileRevision: 1
        ))

        var owner = NewSessionConfigurationOwner()
        owner.begin(profileID: "profile-a", workspace: "/workspace/a")
        #expect(owner.isLoading(profileID: "profile-a", workspace: "/workspace/a"))
        #expect(!owner.permitsCreation(
            profileID: "profile-a",
            workspace: "/workspace/a"
        ))

        let admittedA = owner.admit(
            profileID: "profile-a",
            workspace: "/workspace/a",
            settingsReady: true,
            trustReady: true
        )
        #expect(admittedA)
        #expect(!owner.isLoading(profileID: "profile-a", workspace: "/workspace/a"))
        #expect(owner.permitsCreation(
            profileID: "profile-a",
            workspace: "/workspace/a"
        ))
        #expect(!owner.permitsCreation(
            profileID: "profile-b",
            workspace: "/workspace/a"
        ))
        #expect(owner.isLoading(profileID: "profile-b", workspace: "/workspace/a"))

        owner.begin(profileID: "profile-b", workspace: "/workspace/b")
        let admittedStaleA = owner.admit(
            profileID: "profile-a",
            workspace: "/workspace/a",
            settingsReady: true,
            trustReady: true
        )
        #expect(!admittedStaleA)
        let admittedWithoutTrust = owner.admit(
            profileID: "profile-b",
            workspace: "/workspace/b",
            settingsReady: true,
            trustReady: false
        )
        #expect(!admittedWithoutTrust)
        let admittedB = owner.admit(
            profileID: "profile-b",
            workspace: "/workspace/b",
            settingsReady: true,
            trustReady: true
        )
        #expect(admittedB)
    }

    @Test("an unresolved trust prompt defaults creation to blocked project resources")
    func unresolvedTrustFallback() {
        let unresolved = JSONValue.object([
            "requiresDecision": .bool(true),
            "effectiveDecision": .null
        ])
        let trusted = JSONValue.object([
            "requiresDecision": .bool(true),
            "effectiveDecision": .bool(true)
        ])
        let notRequired = JSONValue.object([
            "requiresDecision": .bool(false),
            "effectiveDecision": .null
        ])

        #expect(NewSessionTrustPolicy.requiresDecision(unresolved))
        #expect(NewSessionTrustPolicy.decisionBeforeCreation(unresolved) == false)
        #expect(!NewSessionTrustPolicy.requiresDecision(trusted))
        #expect(NewSessionTrustPolicy.decisionBeforeCreation(trusted) == nil)
        #expect(!NewSessionTrustPolicy.requiresDecision(notRequired))
        #expect(NewSessionTrustPolicy.decisionBeforeCreation(notRequired) == nil)
        #expect(NewSessionTrustPolicy.decisionBeforeCreation(nil) == nil)
    }

    @Test("one creation gesture owns the mutation until terminal completion")
    func creationSingleFlight() {
        var owner = NewSessionCreationOwner()
        let rejectedWhileLoading = owner.begin(configurationReady: false)
        #expect(!rejectedWhileLoading)
        let admitted = owner.begin(configurationReady: true)
        #expect(admitted)
        #expect(owner.isCreating)
        let rejectedDuplicate = owner.begin(configurationReady: true)
        #expect(!rejectedDuplicate)

        owner.finish()
        #expect(!owner.isCreating)
        let admittedRetry = owner.begin(configurationReady: true)
        #expect(admittedRetry)
    }

    @Test("only an explicit model choice overrides the configured session default")
    func modelOverridePolicy() {
        let configured = ModelRef(provider: "provider", id: "configured")
        let explicit = ModelRef(provider: "provider", id: "explicit")
        let owner = NewSessionCreationOwner()

        #expect(owner.modelOverride(selected: configured, configured: configured) == nil)
        #expect(owner.modelOverride(selected: explicit, configured: configured) == explicit)
        #expect(owner.modelOverride(selected: explicit, configured: nil) == explicit)
        #expect(owner.modelOverride(selected: nil, configured: configured) == nil)
    }

    @Test("a created route carries its explicit model until the opened chat applies it")
    func createdRouteCarriesInitialModel() {
        let route = AppModel.SessionNavigationRoute(sessionID: "created", editorText: nil)
            .withInitialModel(ModelRef(provider: "openai-codex", id: "gpt-5.6-luna"))
        #expect(route.initialModel == ModelRef(provider: "openai-codex", id: "gpt-5.6-luna"))
        #expect(route.sessionID == "created")
    }
}
