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

    @Test("a scope round trip invalidates an older save completion")
    func scopeRoundTrip() {
        var store = ScopedSettingsDraftStore<String>()
        let installed = store.install("baseline", for: .global)
        #expect(installed)
        store.update("saving edit", for: .global)
        let savingRevision = store.revision(for: .global)!

        store.update("saving edit", for: .global)
        let markedSaved = store.markSaved(
            "saving edit",
            for: .global,
            expectedRevision: savingRevision
        )

        #expect(!markedSaved)
        #expect(store.isDirty(.global))
    }

    @Test("an edit made before the first response still rejects that response")
    func prepublicationEdit() {
        var store = ScopedSettingsDraftStore<String>()
        store.update("fast edit", for: .global)

        #expect(store.isDirty(.global))
        let installedLateInitial = store.install("late initial response", for: .global)
        #expect(!installedLateInitial)
        #expect(store.draft(for: .global) == "fast edit")
    }
}
