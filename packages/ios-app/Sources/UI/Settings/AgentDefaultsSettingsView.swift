import SwiftUI

struct AgentDefaultsDraft: Equatable {
    var selectedModel: ModelRef?
    var thinking = "medium"
    var retry = true
    var trust = "ask"
    /// Sparse values owned by this settings scope. Effective inherited values
    /// are kept separately so selecting a model never creates a write.
    var modelContextWindows: [String: Int] = [:]
    var inheritedModelContextWindows: [String: Int] = [:]
    var contextWindowMinimum: Int? = nil

    func contextWindowOverride(for model: ModelRef) -> Int? {
        modelContextWindows[model.contextWindowKey]
    }

    mutating func setContextWindowOverride(_ value: Int?, for model: ModelRef) {
        modelContextWindows[model.contextWindowKey] = value
    }

    func patch(comparedTo baseline: Self) -> JSONValue {
        var patch: [String: JSONValue] = [:]
        if thinking != baseline.thinking { patch["defaultThinkingLevel"] = .string(thinking) }
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
        let keys = Set(modelContextWindows.keys).union(baseline.modelContextWindows.keys)
        var contextPatch: [String: JSONValue] = [:]
        for key in keys {
            if let value = modelContextWindows[key] {
                if baseline.modelContextWindows[key] != value { contextPatch[key] = .number(Double(value)) }
            } else if baseline.modelContextWindows[key] != nil {
                contextPatch[key] = .null
            }
        }
        if !contextPatch.isEmpty { patch["modelContextWindows"] = .object(contextPatch) }
        return .object(patch)
    }
}

struct AgentDefaultsSettingsView: View {
    @Environment(AppModel.self) private var model
    let allowsProjectScope: Bool
    let providerTarget: ProviderCatalogTarget
    let projectCWD: String?
    let projectSessionID: String?
    @State private var draft = AgentDefaultsDraft()
    @State private var drafts = ScopedSettingsDraftStore<AgentDefaultsDraft>()
    @State private var scope: SettingsScope = .global
    @State private var saving = false
    @State private var refreshingCatalog = false

    init(
        allowsProjectScope: Bool,
        providerTarget: ProviderCatalogTarget,
        projectCWD: String?,
        projectSessionID: String? = nil
    ) {
        self.allowsProjectScope = allowsProjectScope
        self.providerTarget = providerTarget
        self.projectCWD = projectCWD
        self.projectSessionID = projectSessionID
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup(
                    "Scope",
                    detail: scope == .project
                        ? "Overrides apply only to the trusted current workspace."
                        : "Defaults apply to every Tron workspace on this Mac."
                ) {
                    if allowsProjectScope {
                        TronValueRow(
                            icon: "scope",
                            title: "Settings Scope",
                            value: scope == .project ? "Current Project" : "Global Defaults"
                        ) {
                            TronInlineMenu("Change") {
                                Button("Global Defaults") { selectScope(.global) }
                                Button("Current Project") { selectScope(.project) }
                            }
                        }
                    } else {
                        TronValueRow(
                            icon: "scope",
                            title: "Settings Scope",
                            value: "Global Defaults"
                        )
                    }
                }
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    TronSettingsGroup("Default Model", accent: .tronPurple) {
                        VStack(spacing: 0) {
                            TronModelSelectionRow(
                                selection: $draft.selectedModel,
                                models: availableModels,
                                navigationTitle: "Default Model"
                            )
                            if model.gatewayInfo?.capabilities.contains("context-window.v1") == true,
                               let selectedModel, let limits = selectedContextWindowLimits {
                                TronSettingsDivider(accent: .tronPurple)
                                ContextWindowSelectionRow(
                                    selection: contextWindowBinding(for: selectedModel),
                                    limits: limits,
                                    inheritedValue: draft.inheritedModelContextWindows[selectedModel.ref.contextWindowKey],
                                    resetLabel: scope == .project ? "Use inherited default" : "Use model default"
                                )
                                .id("\(scope.rawValue):\(selectedModel.ref.contextWindowKey)")
                                Text("Defaults apply to new sessions and after reloading session resources. Use Manage Session to change a live session. Larger windows do not restore compacted history.")
                                    .font(TronTypography.secondaryDescription)
                                    .foregroundStyle(Color.tronTextSecondary)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 10)
                            }
                            TronSettingsDivider(accent: .tronPurple)
                            TronThinkingSelectionRow(
                                selection: $draft.thinking,
                                levels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
                            )
                        }
                    }
                    refreshModelCatalogButton
                }
                TronSettingsGroup("Context", accent: .tronTeal) {
                    VStack(spacing: 0) {
                        TronToggleRow(
                            icon: "arrow.clockwise",
                            title: "Automatic Retry",
                            detail: "Retry transient agent and provider failures",
                            accent: .tronTeal,
                            isOn: $draft.retry
                        )
                    }
                }
                TronSettingsGroup(
                    "Project Resources",
                    detail: "Trust controls project resource loading; it is not a sandbox.",
                    accent: .tronAmber
                ) {
                    TronValueRow(
                        icon: "checkmark.shield",
                        title: "Default Trust",
                        value: draft.trust.capitalized,
                        accent: .tronAmber
                    ) {
                        TronInlineMenu("Change", accent: .tronAmber) {
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
                TronSaveToolbarButton(
                    isSaving: saving,
                    isEnabled: hasUnsavedChanges && !refreshingCatalog
                ) {
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

    private var availableModels: [ModelSummary] {
        model.providerCatalog(for: catalogTarget)?.models.filter(\.available) ?? []
    }

    private var selectedModel: ModelSummary? {
        guard let selected = draft.selectedModel else { return nil }
        return availableModels.first(where: { $0.ref == selected })
    }

    private var selectedContextWindowLimits: ContextWindowLimits? {
        selectedModel?.contextWindowLimits?.withMinimum(draft.contextWindowMinimum)
    }

    private func contextWindowBinding(for modelSummary: ModelSummary) -> Binding<Int?> {
        Binding(
            get: { draft.contextWindowOverride(for: modelSummary.ref) },
            set: { value in
                draft.setContextWindowOverride(value, for: modelSummary.ref)
            }
        )
    }

    private var refreshModelCatalogButton: some View {
        Button {
            Task { await refreshModelCatalog() }
        } label: {
            TronSettingsRow(
                icon: "arrow.clockwise",
                title: "Refresh Model Catalog",
                subtitle: refreshingCatalog ? "Checking configured providers…" : modelCatalogSummary,
                accent: .tronPurple
            ) {
                if refreshingCatalog {
                    TronPulseLoadingIndicator(size: 18)
                        .accessibilityLabel("Refreshing model catalog")
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronPurple)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(refreshingCatalog || saving)
        .tronGlassSurface(
            accent: .tronPurple,
            tintOpacity: 0.14,
            interactive: !refreshingCatalog && !saving
        )
        .accessibilityLabel("Refresh Model Catalog")
        .accessibilityValue(refreshingCatalog ? "In progress" : modelCatalogSummary)
        .accessibilityHint("Checks configured providers for newly available models.")
    }

    private var modelCatalogSummary: String {
        guard model.providerCatalog(for: catalogTarget) != nil else { return "Catalog not loaded" }
        return availableModels.count == 1
            ? "1 model currently available"
            : "\(availableModels.count) models currently available"
    }

    private var hasUnsavedChanges: Bool {
        guard let target = settingsTarget else { return false }
        return drafts.hasChanges(draft, for: target)
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
        _ = drafts.seedBaselineIfMissing(draft, for: target)
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
        let scopeDocument = root["documents"]?.objectValue?[target.scope.rawValue]?.objectValue ?? [:]
        let scopedContextWindows = Self.contextWindows(scopeDocument["modelContextWindows"])
        let inheritedContextWindows = target.scope == .project
            ? Self.contextWindows(root["documents"]?.objectValue?["global"]?.objectValue?["modelContextWindows"])
            : [:]
        let projected = AgentDefaultsDraft(
            selectedModel: selectedModel,
            thinking: value["defaultThinkingLevel"]?.stringValue ?? "medium",
            retry: value["retry"]?.objectValue?["enabled"]?.boolValue ?? true,
            trust: value["defaultProjectTrust"]?.stringValue ?? "ask",
            modelContextWindows: scopedContextWindows,
            inheritedModelContextWindows: inheritedContextWindows,
            contextWindowMinimum: value["contextWindowMinimum"]?.intValue
        )
        if drafts.install(projected, for: target, ifCurrent: draft) {
            draft = projected
        } else if let saved = drafts.draft(for: target) {
            draft = saved
        }
    }

    private static func contextWindows(_ value: JSONValue?) -> [String: Int] {
        guard let object = value?.objectValue else { return [:] }
        return object.compactMapValues { value in
            guard let number = value.intValue, number > 0 else { return nil }
            return number
        }
    }

    private func refreshModelCatalog() async {
        guard !refreshingCatalog, !saving else { return }
        let requestedTarget = catalogTarget
        refreshingCatalog = true
        defer { refreshingCatalog = false }
        do {
            try await model.refreshModelCatalog(target: requestedTarget, force: true)
        } catch is CancellationError {
            // Profile replacement retires the old target and its presentation.
        } catch {
            model.presentError(error)
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
            try await model.updateSettings(
                patch,
                target: target,
                sessionID: target.scope == .project ? projectSessionID : nil
            )
            guard target == settingsTarget, draft == savingDraft else { return }
            _ = drafts.markSaved(
                savingDraft,
                for: target,
                expectedRevision: savingRevision
            )
        } catch {
            model.presentError(error)
        }
    }
}
