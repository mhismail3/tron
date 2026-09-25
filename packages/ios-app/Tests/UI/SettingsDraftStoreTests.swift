import Testing
@testable import TronMobile

@Suite("Scoped settings drafts")
struct SettingsDraftStoreTests {

    @Test("settings patches contain only changed fields")
    func changedFieldsOnly() {
        var runtime = AgentDefaultsDraft()
        runtime.providerRetryCount = 7
        let runtimePatch = runtime.patch(comparedTo: AgentDefaultsDraft()).objectValue
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
        defaults.retryEnabled = false
        let defaultsPatch = defaults.patch(comparedTo: AgentDefaultsDraft()).objectValue
        #expect(defaultsPatch == [
            "retry": .object(["enabled": .bool(false)])
        ])
    }

    @Test("context window defaults patch only changed model keys and supports scope reset")
    func modelContextWindowPatch() {
        let model = ModelRef(provider: "openai-codex", id: "gpt-6-astra")
        var baseline = AgentDefaultsDraft()
        baseline.modelContextWindows[model.contextWindowKey] = 272_000
        var edited = baseline
        edited.modelContextWindows["other/model"] = 128_000
        edited.modelContextWindows[model.contextWindowKey] = nil

        #expect(edited.patch(comparedTo: baseline).objectValue?["modelContextWindows"]?.objectValue == [
            model.contextWindowKey: .null,
            "other/model": .number(128_000)
        ])
        #expect(edited.patch(comparedTo: edited).objectValue?.isEmpty == true)
    }

    @Test("context drafts retain other models and reveal inheritance without writing it")
    func contextWindowInheritance() {
        let model = ModelRef(provider: "p", id: "m"); let other = ModelRef(provider: "p", id: "other")
        var baseline = AgentDefaultsDraft()
        baseline.modelContextWindows = [model.contextWindowKey: 500_000, other.contextWindowKey: 100_000]
        baseline.inheritedModelContextWindows = [model.contextWindowKey: 272_000]
        var draft = baseline
        draft.modelContextWindows[model.contextWindowKey] = nil
        #expect(draft.inheritedModelContextWindows[model.contextWindowKey] == 272_000)
        #expect(draft.modelContextWindows[other.contextWindowKey] == 100_000)
        #expect(draft.patch(comparedTo: baseline).objectValue?["modelContextWindows"] == .object([model.contextWindowKey: .null]))
        draft.modelContextWindows[model.contextWindowKey] = 500_000
        #expect(draft.patch(comparedTo: baseline).objectValue?.isEmpty == true)
    }

    @Test("compaction instructions use the Gateway UTF-16 bound without cutting scalars")
    func compactionInstructionLimit() {
        let bounded = CompactionSettingsDraft.boundedInstructions(String(repeating: "😀", count: 2_001))
        #expect(bounded.count == 2_000)
        #expect(bounded.utf16.count == 4_000)
    }

    @Test("compaction standard reset changes policy fields without changing budgets")
    func compactionPolicyDraft() {
        var baseline = CompactionSettingsDraft()
        baseline.thinkingLevel = "low"
        baseline.instructions = "focus"
        var restored = baseline
        restored.restoreStandard()
        #expect(restored.patch(comparedTo: baseline).objectValue?["compaction"]?.objectValue == [
            "thinkingLevel": .string("inherit"),
            "instructions": .string("")
        ])
        #expect(restored.reserveTokens == baseline.reserveTokens)
        #expect(restored.keepRecentTokens == baseline.keepRecentTokens)
        var standard = CompactionSettingsDraft()
        standard.restoreStandard()
        #expect(standard.patch(comparedTo: CompactionSettingsDraft()).objectValue?["compaction"]?.objectValue == [
            "thinkingLevel": .string("inherit"), "instructions": .string("")
        ])
    }

    @Test("branch summary reserve patches its own settings key beside compaction")
    func branchSummaryReservePatch() {
        var edited = CompactionSettingsDraft()
        edited.branchReserveTokens = 8_192
        #expect(edited.patch(comparedTo: CompactionSettingsDraft()).objectValue == [
            "branchSummary": .object(["reserveTokens": .number(8_192)])
        ])
        #expect(edited.patch(comparedTo: edited).objectValue?.isEmpty == true)
    }

    @Test("project compaction overrides can be deleted without changing budgets")
    func compactionProjectInheritance() {
        var baseline = CompactionSettingsDraft()
        baseline.thinkingLevel = "low"
        baseline.instructions = "project focus"
        var global = CompactionSettingsDraft()
        global.thinkingLevel = "high"
        global.instructions = "global focus"
        var project = baseline
        project.useGlobalPolicy(from: global)

        #expect(project.patch(comparedTo: baseline).objectValue?[
            "compaction"
        ]?.objectValue == [
            "thinkingLevel": .null,
            "instructions": .null,
        ])
        #expect(project.reserveTokens == baseline.reserveTokens)
        #expect(project.keepRecentTokens == baseline.keepRecentTokens)
        #expect(project.afterSuccessfulSave().useGlobalFields.isEmpty)

        project.setThinkingLevel("medium")
        #expect(project.patch(comparedTo: baseline).objectValue?["compaction"]?.objectValue == [
            "thinkingLevel": .string("medium"),
            "instructions": .null,
        ])
        project.useGlobalPolicy(from: global)
        project.setInstructions("new project focus")
        #expect(project.patch(comparedTo: baseline).objectValue?["compaction"]?.objectValue == [
            "thinkingLevel": .null,
            "instructions": .string("new project focus"),
        ])
    }

    @Test("compaction reset intent is cleared before a later budget-only save")
    func compactionResetThenBudgetEdit() {
        let target = SettingsTarget.global
        var baseline = CompactionSettingsDraft()
        baseline.thinkingLevel = "low"
        baseline.instructions = "focus"

        var store = ScopedSettingsDraftStore<CompactionSettingsDraft>()
        let installed = store.install(baseline, for: target)
        #expect(installed)

        var reset = baseline
        reset.restoreStandard()
        store.update(reset, for: target)
        let resetRevision = store.revision(for: target)!
        #expect(reset.patch(comparedTo: baseline).objectValue?["compaction"]?.objectValue == [
            "thinkingLevel": .string("inherit"),
            "instructions": .string("")
        ])
        let markedSaved = store.markSaved(
            submitted: reset,
            resulting: reset.afterSuccessfulSave(),
            for: target,
            expectedRevision: resetRevision
        )
        #expect(markedSaved)
        #expect(store.draft(for: target)?.restoreStandardRequested == false)

        var budgetEdit = store.draft(for: target)!
        budgetEdit.reserveTokens += 1
        store.update(budgetEdit, for: target)
        let budgetPatch = budgetEdit.patch(comparedTo: store.baseline(for: target)!).objectValue
        #expect(budgetPatch == [
            "compaction": .object(["reserveTokens": .number(Double(budgetEdit.reserveTokens))])
        ])
    }

    @Test("context window minimum preserves valid default and capacity")
    func contextWindowMinimum() {
        let limits = ContextWindowLimits(minimum: 37_408, maximum: 1_050_000, default: 272_000, longContextThreshold: 272_000)
        #expect(limits.withMinimum(300_000).minimum == 300_000)
        #expect(limits.withMinimum(300_000).default == 300_000)
        #expect(limits.withMinimum(300_000).isValid)
        #expect(limits.withMinimum(2_000_000).minimum == 1_050_000)
    }

    @Test("context window limits reject malformed numeric capabilities")
    func contextWindowLimitsValidation() {
        let limits = ContextWindowLimits(minimum: 1, maximum: 1_050_000, default: 272_000, longContextThreshold: 272_000)
        #expect(limits.isValid)
        #expect(limits.admits(1))
        #expect(limits.admits(1_050_000))
        #expect(!limits.admits(1_050_001))
        #expect(!ContextWindowLimits(minimum: 0, maximum: 1_000, default: 500, longContextThreshold: nil).isValid)
        #expect(!ContextWindowLimits(minimum: 1_000, maximum: 500, default: 500, longContextThreshold: nil).isValid)
        #expect(!ContextWindowLimits(minimum: 1, maximum: 1_000, default: 2_000, longContextThreshold: nil).isValid)
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

    @Test("a clean initial snapshot enables saving only after an edit")
    func cleanInitialSnapshotTracksEditsAndSavedState() {
        var store = ScopedSettingsDraftStore<String>()
        let target = SettingsTarget.global

        let installed = store.install("loaded", for: target)
        #expect(installed)
        #expect(!store.isDirty(target))

        store.update("edited", for: target)
        #expect(store.isDirty(target))

        let revision = store.revision(for: target)!
        let saved = store.markSaved("edited", for: target, expectedRevision: revision)
        #expect(saved)
        #expect(!store.isDirty(target))

        store.update("edited again", for: target)
        #expect(store.isDirty(target))
    }

    @Test("the presented draft closes the SwiftUI onChange gap")
    func presentedDraftOwnsDirtyStateAndLatePublicationAdmission() {
        var store = ScopedSettingsDraftStore<String>()
        let target = SettingsTarget.global
        let installed = store.install("loaded", for: target)
        #expect(installed)
        #expect(!store.isDirty(target))

        // The field has changed, but SwiftUI has not delivered onChange yet.
        let presented = "edited"
        #expect(store.hasChanges(presented, for: target))
        #expect(!store.isDirty(target))
        let reseededDuringRefresh = store.seedBaselineIfMissing(presented, for: target)
        #expect(!reseededDuringRefresh)
        let installedLateResponse = store.install("late response", for: target, ifCurrent: presented)
        #expect(!installedLateResponse)
        #expect(store.baseline(for: target) == "loaded")

        store.update(presented, for: target)
        let revision = store.revision(for: target)!
        let markedSaved = store.markSaved(presented, for: target, expectedRevision: revision)
        #expect(markedSaved)
        #expect(!store.hasChanges(presented, for: target))
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

    @Test("a scope round trip preserves unchanged autosave receipt authority")
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
        #expect(markedSaved)
        #expect(!store.isDirty(.global))
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
