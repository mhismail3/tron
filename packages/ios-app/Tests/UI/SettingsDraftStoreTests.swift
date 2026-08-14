import Testing
@testable import TronMobile

@Suite("Scoped settings drafts")
struct SettingsDraftStoreTests {
    @Test("default settings reload identity includes the active provider target")
    func providerTargetIdentity() {
        let global = AgentDefaultsLoadID(
            settingsTarget: .global,
            providerTarget: .global,
            settingsInvalidationGeneration: 0,
            providerInvalidationGeneration: 0
        )
        let project = AgentDefaultsLoadID(
            settingsTarget: .project(cwd: "/workspace/project"),
            providerTarget: .session(id: "session-a"),
            settingsInvalidationGeneration: 0,
            providerInvalidationGeneration: 0
        )
        #expect(global != project)
        #expect(global != AgentDefaultsLoadID(
            settingsTarget: .global,
            providerTarget: .global,
            settingsInvalidationGeneration: 0,
            providerInvalidationGeneration: 1
        ))
    }

    @Test("settings patches contain only changed fields")
    func changedFieldsOnly() {
        var runtime = RuntimeBehaviorDraft()
        runtime.providerRetryCount = 7
        let runtimePatch = runtime.patch(comparedTo: RuntimeBehaviorDraft()).objectValue
        #expect(runtimePatch?.count == 1)
        #expect(runtimePatch?["retry"]?.objectValue?.count == 1)
        #expect(runtimePatch?["retry"]?.objectValue?["provider"]?.objectValue == [
            "maxRetries": .number(7)
        ])

        var resources = ResourceSettingsDraft()
        resources.skills = "/project/skill"
        let resourcePatch = resources.patch(comparedTo: ResourceSettingsDraft()).objectValue
        #expect(resourcePatch == [
            "skills": .array([.string("/project/skill")])
        ])

        var defaults = AgentDefaultsDraft()
        defaults.retry = false
        let defaultsPatch = defaults.patch(comparedTo: AgentDefaultsDraft()).objectValue
        #expect(defaultsPatch == [
            "retry": .object(["enabled": .bool(false)])
        ])
    }

    @Test("proxy writes are explicit, redacted after save, and can be cleared")
    func proxyPatch() {
        var configured = ResourceSettingsDraft()
        configured.proxyConfigured = true
        var clearing = configured
        clearing.proxyEdited = true
        #expect(clearing.patch(comparedTo: configured).objectValue?["httpProxy"] == .null)
        let clearedWithoutProjection = clearing.afterSuccessfulSave()
        #expect(clearedWithoutProjection.proxyConfigured)
        #expect(!clearedWithoutProjection.proxyEdited)

        var setting = configured
        setting.proxy = "http://proxy.invalid"
        setting.proxyEdited = true
        #expect(setting.patch(comparedTo: configured).objectValue?["httpProxy"] == .string(setting.proxy))
        let saved = setting.afterSuccessfulSave()
        #expect(saved.proxy.isEmpty)
        #expect(!saved.proxyEdited)
        #expect(saved.proxyConfigured)
    }

    @Test("runtime drafts preserve independent global and project edits")
    func runtimeDraftTargets() {
        let project = SettingsTarget.project(cwd: "/workspace/project")
        var store = ScopedSettingsDraftStore<RuntimeBehaviorDraft>()
        var global = RuntimeBehaviorDraft()
        global.transport = "sse"
        store.update(global, for: .global)
        var projectDraft = RuntimeBehaviorDraft()
        projectDraft.retryCount = 9
        store.update(projectDraft, for: project)

        #expect(store.draft(for: .global)?.transport == "sse")
        #expect(store.draft(for: .global)?.retryCount == 3)
        #expect(store.draft(for: project)?.transport == "auto")
        #expect(store.draft(for: project)?.retryCount == 9)
    }

    @Test("resource edits made before publication reject only their target response")
    func resourceDraftBeforeResponse() {
        let project = SettingsTarget.project(cwd: "/workspace/project")
        var store = ScopedSettingsDraftStore<ResourceSettingsDraft>()
        var global = ResourceSettingsDraft()
        global.skills = "/global/skill"
        store.update(global, for: .global)

        var loadedGlobal = ResourceSettingsDraft()
        loadedGlobal.skills = "/published/global"
        var loadedProject = ResourceSettingsDraft()
        loadedProject.skills = "/published/project"
        let installedGlobal = store.install(loadedGlobal, for: .global)
        let installedProject = store.install(loadedProject, for: project)

        #expect(!installedGlobal)
        #expect(installedProject)
        #expect(store.draft(for: .global)?.skills == "/global/skill")
        #expect(store.draft(for: project)?.skills == "/published/project")
    }

    @Test("dirty drafts remain isolated by target and reject reload publication")
    func targetIsolation() {
        var store = ScopedSettingsDraftStore<String>()
        let project = SettingsTarget.project(cwd: "/workspace/project")

        let installedGlobal = store.install("global baseline", for: .global)
        #expect(installedGlobal)
        store.update("global edit", for: .global)
        #expect(store.isDirty(.global))
        let installedOverDirtyGlobal = store.install("external global", for: .global)
        #expect(!installedOverDirtyGlobal)
        #expect(store.draft(for: .global) == "global edit")

        let installedProject = store.install("project baseline", for: project)
        #expect(installedProject)
        store.update("project edit", for: project)
        #expect(store.draft(for: project) == "project edit")
        #expect(store.draft(for: .global) == "global edit")

        let globalRevision = store.revision(for: .global)!
        let markedGlobalSaved = store.markSaved(
            "global edit",
            for: .global,
            expectedRevision: globalRevision
        )
        #expect(markedGlobalSaved)
        #expect(!store.isDirty(.global))
        let installedNewGlobal = store.install("new global baseline", for: .global)
        #expect(installedNewGlobal)
        #expect(store.draft(for: .global) == "new global baseline")
    }

    @Test("a stale save cannot mark a newer same-target draft clean")
    func staleSave() {
        var store = ScopedSettingsDraftStore<String>()
        let installed = store.install("baseline", for: .global)
        #expect(installed)
        store.update("saving edit", for: .global)
        let savingRevision = store.revision(for: .global)!

        store.update("newer edit", for: .global)
        let markedSaved = store.markSaved(
            "saving edit",
            for: .global,
            expectedRevision: savingRevision
        )

        #expect(!markedSaved)
        #expect(store.isDirty(.global))
        #expect(store.draft(for: .global) == "newer edit")
    }

    @Test("a scope round trip restores each target and invalidates an older save")
    func scopeRoundTrip() {
        let project = SettingsTarget.project(cwd: "/workspace/project")
        var store = ScopedSettingsDraftStore<String>()
        let installed = store.install("baseline", for: .global)
        #expect(installed)
        store.update("saving edit", for: .global)
        let savingRevision = store.revision(for: .global)!

        let projectDraft = store.draftForScopeSwitch(
            current: "saving edit",
            from: .global,
            to: project,
            default: "project default"
        )
        let restoredGlobal = store.draftForScopeSwitch(
            current: "project edit",
            from: project,
            to: .global,
            default: "unused"
        )
        let markedSaved = store.markSaved(
            "saving edit",
            for: .global,
            expectedRevision: savingRevision
        )

        #expect(projectDraft == "project default")
        #expect(restoredGlobal == "saving edit")
        #expect(store.draft(for: project) == "project edit")
        #expect(!markedSaved)
        #expect(store.isDirty(.global))
    }

    @Test("an edit made before the first response still rejects that response")
    func prepublicationEdit() {
        var store = ScopedSettingsDraftStore<String>()
        store.update("fast edit", for: .global)

        #expect(store.isDirty(.global))
        #expect(store.baseline(for: .global) == nil)
        let installedLateInitial = store.install("late initial response", for: .global)
        #expect(!installedLateInitial)
        #expect(store.draft(for: .global) == "fast edit")
    }
}
