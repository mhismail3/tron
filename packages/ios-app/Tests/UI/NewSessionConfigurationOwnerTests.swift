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

    @Test("a background revision change keeps the model the user just chose")
    func modelChoiceSurvivesRevisionReruns() {
        // Reported defect: pick a model, then dismiss the picker and the row
        // snapped back to the scope default. The configuration task re-runs on
        // profile revision, trust invalidation, or presentation activity -- a
        // profile switch completing in the background, or a `trust.changed`
        // event -- and every re-run re-derived the default over the selection.
        let scope = NewSessionModelScope(profileID: "profile-a", workspace: "/workspace/testspace")
        let chosen = ModelRef(provider: "deepseek", id: "deepseek-v4.1")
        let configured = ModelRef(provider: "openai-codex", id: "gpt-6-astra")
        var choice = NewSessionModelChoice()
        choice.choose(chosen, scope: scope)

        // Any number of revision-only re-runs resolve to the same explicit pick.
        for _ in 0..<3 {
            #expect(choice.retain(in: scope) == chosen)
            #expect(choice.effective(configured: configured, preferred: configured) == chosen)
        }
    }

    @Test("a real scope change drops the choice and re-derives the default")
    func modelChoiceDropsOnScopeChange() {
        let chosen = ModelRef(provider: "deepseek", id: "deepseek-v4.1")
        let configured = ModelRef(provider: "openai-codex", id: "gpt-6-astra")
        var choice = NewSessionModelChoice()
        choice.choose(chosen, scope: NewSessionModelScope(profileID: "profile-a", workspace: "/workspace/testspace"))

        // Another server, then another directory: each drops explicit intent.
        #expect(choice.retain(in: NewSessionModelScope(profileID: "profile-b", workspace: "/workspace/testspace")) == nil)
        #expect(choice.effective(configured: configured, preferred: nil) == configured)
        #expect(choice.model == nil)

        choice.choose(chosen, scope: NewSessionModelScope(profileID: "profile-a", workspace: "/workspace/testspace"))
        #expect(choice.retain(in: NewSessionModelScope(profileID: "profile-a", workspace: "/workspace/other")) == nil)
    }

    @Test("the effective selection falls back from intent to default to preferred")
    func modelChoiceFallbackOrder() {
        let chosen = ModelRef(provider: "deepseek", id: "deepseek-v4.1")
        let configured = ModelRef(provider: "openai-codex", id: "gpt-6-astra")
        let preferred = ModelRef(provider: "openai-codex", id: "gpt-5.6-luna")
        let scope = NewSessionModelScope(profileID: "profile-a", workspace: "/workspace/testspace")

        var choice = NewSessionModelChoice()
        #expect(choice.retain(in: scope) == nil)
        #expect(choice.effective(configured: configured, preferred: preferred) == configured)
        #expect(choice.effective(configured: nil, preferred: preferred) == preferred)
        #expect(choice.effective(configured: nil, preferred: nil) == nil)

        // Clearing to "Default" in the picker is itself an explicit decision that
        // must also survive a revision-only re-run.
        choice.choose(nil, scope: scope)
        #expect(choice.retain(in: scope) == nil)
        #expect(choice.scope == scope)
        #expect(choice.effective(configured: configured, preferred: preferred) == configured)
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
}
