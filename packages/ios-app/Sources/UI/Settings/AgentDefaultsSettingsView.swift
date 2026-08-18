import SwiftUI

struct AgentDefaultsDraft: Equatable {
    var selectedModel: ModelRef?
    var thinking = "medium"
    var compaction = true
    var retry = true
    var trust = "ask"

    func patch(comparedTo baseline: Self) -> JSONValue {
        var patch: [String: JSONValue] = [:]
        if thinking != baseline.thinking { patch["defaultThinkingLevel"] = .string(thinking) }
        if compaction != baseline.compaction {
            patch["compaction"] = .object(["enabled": .bool(compaction)])
        }
        if retry != baseline.retry { patch["retry"] = .object(["enabled": .bool(retry)]) }
        if trust != baseline.trust { patch["defaultProjectTrust"] = .string(trust) }
        if selectedModel != baseline.selectedModel {
            if let selectedModel {
                patch["defaultModel"] = .object([
                    "provider": .string(selectedModel.provider),
                    "id": .string(selectedModel.id),
                ])
            } else {
                patch["defaultModel"] = .null
            }
        }
        return .object(patch)
    }
}

struct AgentDefaultsSettingsView: View {
    @Environment(AppModel.self) private var model
    let allowsProjectScope: Bool
    let providerTarget: ProviderCatalogTarget
    let projectCWD: String?
    @State private var draft = AgentDefaultsDraft()
    @State private var drafts = ScopedSettingsDraftStore<AgentDefaultsDraft>()
    @State private var scope: SettingsScope = .global
    @State private var saving = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Scope") {
                    TronValueRow(icon: "scope", title: "Settings Scope") {
                        TronInlineMenu(scope == .project ? "Current Project" : "Global Defaults") {
                            Button("Global Defaults") { selectScope(.global) }
                            if allowsProjectScope {
                                Button("Current Project") { selectScope(.project) }
                            }
                        }
                    }
                    Text(scope == .project ? "Overrides apply only to the trusted current workspace." : "Defaults apply to every Tron workspace on this Mac.")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
                TronSettingsGroup("Default Model", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        TronProgressiveSheetLink(accessibilityLabel: "Default Model") {
                            ModelPicker(
                                selection: $draft.selectedModel,
                                models: model.providerCatalog(for: catalogTarget)?.models.filter(\.available) ?? []
                            )
                                .tronNavigationTitle("Default Model", accent: .tronPurple)
                        } label: {
                            TronValueRow(icon: "cpu", title: "Model", detail: draft.selectedModel.map { "\($0.provider) / \($0.id)" } ?? "Choose model", accent: .tronPurple)
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        TronValueRow(icon: "brain", title: "Thinking", accent: .tronPurple) {
                            TronInlineMenu(draft.thinking.capitalized, accent: .tronPurple) {
                                ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                                    Button(level.capitalized) { draft.thinking = level }
                                }
                            }
                        }
                    }
                }
                TronSettingsGroup("Context", accent: .tronTeal) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Automatic Compaction", accent: .tronTeal, isOn: $draft.compaction)
                        TronSettingsDivider(accent: .tronTeal)
                        TronToggleRow(icon: "arrow.clockwise", title: "Automatic Retry", accent: .tronTeal, isOn: $draft.retry)
                    }
                }
                TronSettingsGroup("Project Resources", detail: "Trust controls project resource loading; it is not a sandbox.", accent: .tronAmber) {
                    TronValueRow(icon: "checkmark.shield", title: "Default Trust", accent: .tronAmber) {
                        TronInlineMenu(draft.trust.capitalized, accent: .tronAmber) {
                            Button("Ask") { draft.trust = "ask" }
                            Button("Always") { draft.trust = "always" }
                            Button("Never") { draft.trust = "never" }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Models and Defaults")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronSaveToolbarButton(isSaving: saving, isEnabled: hasUnsavedChanges) {
                    Task { await save() }
                }
            }
        }
        .onChange(of: draft) { _, value in
            guard let target = settingsTarget else { return }
            drafts.update(value, for: target)
        }
        .task(id: AgentDefaultsLoadID(
            settingsTarget: settingsTarget,
            providerTarget: catalogTarget,
            settingsInvalidationGeneration: model.settingsInvalidationGeneration,
            providerInvalidationGeneration: model.providerInvalidationGeneration
        )) {
            if !allowsProjectScope { scope = .global }
            await refresh()
        }
    }

    private var settingsTarget: SettingsTarget? {
        SettingsTarget(scope: scope, projectCWD: projectCWD)
    }

    private var catalogTarget: ProviderCatalogTarget {
        scope == .project ? providerTarget : .global
    }

    private var hasUnsavedChanges: Bool {
        guard let target = settingsTarget else { return false }
        return drafts.isDirty(target)
    }

    private func selectScope(_ newScope: SettingsScope) {
        guard newScope != scope,
              let newTarget = SettingsTarget(scope: newScope, projectCWD: projectCWD) else { return }
        let nextDraft = drafts.draftForScopeSwitch(
            current: draft,
            from: settingsTarget,
            to: newTarget,
            default: AgentDefaultsDraft()
        )
        scope = newScope
        draft = nextDraft
    }

    private func refresh() async {
        guard let target = settingsTarget else { return }
        // Establish a clean local snapshot before the first async response. If the
        // user edits while the response is in flight, update() marks the draft dirty
        // and the late response is correctly rejected.
        _ = drafts.install(draft, for: target)
        let requestedCatalogTarget = catalogTarget
        async let settingsReady = model.refreshSettings(target: target)
        async let catalogReady = model.refreshProviders(target: requestedCatalogTarget)
        let (loadedSettings, _) = await (settingsReady, catalogReady)
        guard loadedSettings,
              target == settingsTarget,
              requestedCatalogTarget == catalogTarget else { return }
        load(target: target, catalogTarget: requestedCatalogTarget)
    }

    private func load(target: SettingsTarget, catalogTarget: ProviderCatalogTarget) {
        guard let root = model.settings(for: target)?.objectValue,
              let value = root["effective"]?.objectValue else { return }
        let selectedModel: ModelRef?
        if let object = value["defaultModel"]?.objectValue,
           let provider = object["provider"]?.stringValue,
           let id = object["id"]?.stringValue {
            selectedModel = ModelRef(provider: provider, id: id)
        } else {
            selectedModel = model.preferredAvailableModel(for: catalogTarget)
        }
        let projected = AgentDefaultsDraft(
            selectedModel: selectedModel,
            thinking: value["defaultThinkingLevel"]?.stringValue ?? "medium",
            compaction: value["compaction"]?.objectValue?["enabled"]?.boolValue ?? true,
            retry: value["retry"]?.objectValue?["enabled"]?.boolValue ?? true,
            trust: value["defaultProjectTrust"]?.stringValue ?? "ask"
        )
        if drafts.install(projected, for: target) {
            draft = projected
        } else if let saved = drafts.draft(for: target) {
            draft = saved
        }
    }

    private func save() async {
        guard let target = settingsTarget else { return }
        drafts.update(draft, for: target)
        guard drafts.isDirty(target),
              let savingRevision = drafts.revision(for: target) else { return }
        let savingDraft = draft
        let baseline = drafts.baseline(for: target) ?? AgentDefaultsDraft()
        let patch = savingDraft.patch(comparedTo: baseline)
        saving = true
        defer { saving = false }
        do {
            try await model.updateSettings(patch, target: target)
            guard target == settingsTarget else { return }
            _ = drafts.markSaved(
                savingDraft,
                for: target,
                expectedRevision: savingRevision
            )
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}
